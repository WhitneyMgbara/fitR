#' Metropolis-Hasting MCMC
#'
#' Run \code{n.iterations} of a Metropolis-Hasting MCMC to sample from the target distribution using a gaussian proposal kernel.
#' Two optional optimizations are also implemented: truncated gaussian proposal (to match the support of the target distribution, i.e. boundary of the parameters) and adaptative gaussian proposal (to match the size and the shape of the target distribution).
#' @param target \R-function that takes a single argument: \code{theta} (named numeric vector of parameter values) and returns a list of 2 elements:
#' \itemize{
#' \item \code{log.density} the logged value of the target density, evaluated at \code{theta}.
#' \item \code{trace} a named numeric vector of values to be printed in the \code{trace} data.frame returned by \code{mcmcMH}.
#' }
#' @param init.theta named vector of initial parameter values to start the chain.
#' @param proposal.sd vector of standard deviations. If this is given and covmat is not, a diagonal matrix will be built from this to use as covariance matrix of the multivariate Gaussian proposal distribution. By default, this is set to \code{init.theta/10}.
#' @param n.iterations number of iterations to run the MCMC chain.
#' @param covmat named numeric covariance matrix of the multivariate Gaussian proposal distribution. Must have named rows and columns with at least all estimated theta. If \code{proposal.sd} is given, this is ignored.
#' @param limits limits for the - potentially truncated - multi-variate normal proposal distribution of the MCMC. Contains 2 elements:
#' \itemize{
#'      \item \code{lower} named numeric vector. Lower truncation points in each dimension of the Gaussian proposal distribution. By default they are set to \code{-Inf}.
#'      \item \code{upper} named numeric vector. Upper truncation points in each dimension of the Gaussian proposal distribution. By default they are set to \code{Inf}.
#' }
#' @param adapt.size.start number of iterations to run before adapting the size of the proposal covariance matrix (see note below). Set to 0 (default) if size is not to be adapted.
#' @param adapt.size.cooling cooling factor for the scaling factor of the covariance matrix during size adaptation (see note below).
#' @param adapt.shape.start number of accepted jumps before adapting the shape of the proposal covariance matrix (see note below). Set to 0 (default) if shape is not to be adapted
#' @param print.info.every frequency of information on the chain: acceptance rate and state of the chain. Default value to \code{n.iterations/100}. Set to \code{NULL} to avoid any info.
#' @param verbose logical. If \code{TRUE}, information are printed.
#' @param max.scaling.sd numeric. Maximum value for the scaling factor of the covariance matrix. Avoid too high values for the scaling factor, which might happen due to the exponential update scheme. In this case, the covariance matrix becomes too wide and the sampling from the truncated proposal kernel becomes highly inefficient
#' @note The size of the proposal covariance matrix is adapted using the following formulae: \deqn{\Sigma_{n+1}=\sigma_n * \Sigma_n} with \eqn{\sigma_n=\sigma_{n-1}*exp(\alpha^n*(acc - 0.234))},
#' where \eqn{\alpha} is equal to \code{adapt.size.cooling} and \eqn{acc} is the acceptance rate of the chain.
#'
#' The shape of the proposal covariance matrix is adapted using the following formulae: \deqn{\Sigma_{n+1}=2.38^2/d * \Sigma_n} with \eqn{\Sigma_n} the empirical covariance matrix
#' and \eqn{d} is the number of estimated parameters in the model.
#' @references Roberts GO, Rosenthal JS. Examples of adaptive MCMC. Journal of Computational and Graphical Statistics. Taylor & Francis; 2009;18(2):349-67.
#' @export
#' @import tmvtnorm
#' @importFrom lubridate as.period
#' @return a list with 3 elements:
#' \itemize{
#'      \item \code{trace} a \code{data.frame}. Each row contains a state of the chain (as returned by \code{target}, and an extra column for the log.density).
#'      \item \code{acceptance.rate} acceptance rate of the MCMC chain.
#'      \item \code{covmat.proposal} last covariance matrix used for proposals.
#' }
mcmcMH <- function(target, init.theta, proposal.sd = NULL,
   n.iterations, covmat = NULL,
   limits=list(lower = NULL, upper = NULL),
   adapt.size.start = NULL, adapt.size.cooling = 0.99,
   adapt.shape.start = NULL, adapt.shape.stop = NULL,
   print.info.every = n.iterations/100,
   verbose = FALSE, max.scaling.sd = 50) {

    # initialise theta
    theta.current <- init.theta
    theta.propose <- init.theta

    # extract theta of gaussian proposal
    covmat.proposal <- covmat
    lower.proposal <- limits$lower
    upper.proposal <- limits$upper

    # reorder vector and matrix by names, set to default if necessary
    theta.names <- names(init.theta)
    if (!is.null(proposal.sd) && is.null(names(proposal.sd))) {
        names(proposal.sd) <- theta.names
    }

    if (is.null(covmat.proposal)) {
        if (is.null(proposal.sd)) {
            proposal.sd <- init.theta/10
        }
        covmat.proposal <-
        matrix(diag(proposal.sd[theta.names]^2, nrow = length(theta.names)),
           nrow = length(theta.names),
           dimnames = list(theta.names, theta.names))
    } else {
        covmat.proposal <- covmat.proposal[theta.names,theta.names]
    }

    if (is.null(lower.proposal)) {
        lower.proposal <- init.theta
        lower.proposal[] <- -Inf
    } else {
        lower.proposal <- lower.proposal[theta.names]
    }

    if (is.null(upper.proposal)) {
        upper.proposal <- init.theta
        upper.proposal[] <- Inf
    } else {
        upper.proposal <- upper.proposal[theta.names]
    }

    # covmat init
    covmat.proposal.init <- covmat.proposal

    adapting.size <- FALSE # will be set to TRUE once we start
                           # adapting the size

    adapting.shape <- 0  # will be set to the iteration at which
                         # adaptation starts

    # find estimated theta
    theta.estimated.names <- names(which(diag(covmat.proposal) > 0))

    # evaluate target at theta init
    target.theta.current <- target(theta.current)

    if (!is.null(print.info.every)) {
        message(Sys.time(), ", Init: ", printNamedVector(theta.current[theta.estimated.names]),
            ", target: ", target.theta.current)
    }

    # trace
    trace <- matrix(ncol=length(theta.current)+1, nrow=n.iterations, 0)
    colnames(trace) <- c(theta.estimated.names, "log.density")

    # acceptance rate
    acceptance.rate <- 0

    # scaling factor for covmat size
    scaling.sd  <- 1

    # scaling multiplier
    scaling.multiplier <- 1

    # empirical covariance matrix (0 everywhere initially)
    covmat.empirical <- covmat.proposal
    covmat.empirical[,] <- 0

    # empirical mean vector
    theta.mean <- theta.current

    # if print.info.every is null never print info
    if (is.null(print.info.every)) {
        print.info.every <- n.iterations + 1
    }

    start_iteration_time <- Sys.time()

    for (i.iteration in seq_len(n.iterations)) {

        # adaptive step
        if (!is.null(adapt.size.start) && i.iteration >= adapt.size.start &&
           (is.null(adapt.shape.start) || acceptance.rate*i.iteration < adapt.shape.start)) {
            if (!adapting.size) {
                message("\n---> Start adapting size of covariance matrix")
                adapting.size <- TRUE
            }
            # adapt size of covmat until we get enough accepted jumps
            scaling.multiplier <- exp(adapt.size.cooling^(i.iteration-adapt.size.start) * (acceptance.rate - 0.234))
            scaling.sd <- scaling.sd * scaling.multiplier
            scaling.sd <- min(c(scaling.sd,max.scaling.sd))
            # only scale if it doesn't reduce the covariance matrix to 0
            covmat.proposal.new <- scaling.sd^2*covmat.proposal.init
            if (!(any(diag(covmat.proposal.new)[theta.estimated.names] <
                .Machine$double.eps))) {
                covmat.proposal <- covmat.proposal.new
            }

        } else if (!is.null(adapt.shape.start) &&
                   acceptance.rate*i.iteration >= adapt.shape.start &&
                   (adapting.shape == 0 || is.null(adapt.shape.stop) ||
                    i.iteration < adapting.shape + adapt.shape.stop)) {
            if (!adapting.shape) {
                message("\n---> Start adapting shape of covariance matrix")
                # flush.console()
                adapting.shape <- i.iteration
            }

            ## adapt shape of covmat using optimal scaling factor for multivariate target distributions
            scaling.sd <- 2.38/sqrt(length(theta.estimated.names))

            covmat.proposal <- scaling.sd^2 * covmat.empirical
        } else if (adapting.shape > 0) {
            message("\n---> Stop adapting shape of covariance matrix")
            adapting.shape <- -1
        }

        # print info
        if (i.iteration %% ceiling(print.info.every) == 0) {
            message(Sys.time(), ", Iteration: ",i.iteration,"/", n.iterations,
                ", acceptance rate: ",
                sprintf("%.3f",acceptance.rate), appendLF=FALSE)
            if (!is.null(adapt.size.start) || !is.null(adapt.shape.start)) {
                message(", scaling.sd: ", sprintf("%.3f", scaling.sd),
                    ", scaling.multiplier: ", sprintf("%.3f", scaling.multiplier),
                    appendLF=FALSE)
            }
            message(", state: ",(printNamedVector(theta.current)))
            message(", logdensity: ", target.theta.current)
        }

        # propose another parameter set
        if (any(diag(covmat.proposal)[theta.estimated.names] <
            .Machine$double.eps)) {
            print(covmat.proposal[theta.estimated.names,theta.estimated.names])
            stop("non-positive definite covmat",call.=FALSE)
        }
        if (length(theta.estimated.names) > 0) {
            theta.propose[theta.estimated.names] <-
                as.vector(rtmvnorm(1,
                                   mean =
                                       theta.current[theta.estimated.names],
                                   sigma =
                                       covmat.proposal[theta.estimated.names,theta.estimated.names],
                                   lower =
                                       lower.proposal[theta.estimated.names],
                                   upper = upper.proposal[theta.estimated.names]))
        }

        # evaluate posterior of proposed parameter
        target.theta.propose <- target(theta.propose)
        # if return value is a vector, set log.density and trace

        if (!is.finite(target.theta.propose)) {
            # if posterior is 0 then do not compute anything else and don't accept
            log.acceptance <- -Inf

        }else{

            # compute Metropolis-Hastings ratio (acceptance probability)
            log.acceptance <- target.theta.propose - target.theta.current
            log.acceptance <- log.acceptance +
            dtmvnorm(x = theta.current[theta.estimated.names],
             mean =
             theta.propose[theta.estimated.names],
             sigma =
             covmat.proposal[theta.estimated.names,
             theta.estimated.names],
             lower =
             lower.proposal[theta.estimated.names],
             upper =
             upper.proposal[theta.estimated.names],
             log = TRUE)
            log.acceptance <- log.acceptance -
            dtmvnorm(x = theta.propose[theta.estimated.names],
             mean = theta.current[theta.estimated.names],
             sigma =
             covmat.proposal[theta.estimated.names,
             theta.estimated.names],
             lower =
             lower.proposal[theta.estimated.names],
             upper =
             upper.proposal[theta.estimated.names],
             log = TRUE)

        }

        if (verbose) {
            message("Propose: ", theta.propose[theta.estimated.names],
                ", target: ", target.theta.propose,
                ", acc prob: ", exp(log.acceptance), ", ",
                appendLF = FALSE)
        }

        if (is.accepted <- (log(runif (1)) < log.acceptance)) {
            # accept proposed parameter set
            theta.current <- theta.propose
            target.theta.current <- target.theta.propose
            if (verbose) {
                message("accepted")
            }
        } else if (verbose) {
            message("rejected")
        }
        trace[i.iteration, ] <- c(theta.current, target.theta.current)

        # update acceptance rate
        if (i.iteration == 1) {
            acceptance.rate <- is.accepted
        } else {
            acceptance.rate <- acceptance.rate +
                (is.accepted - acceptance.rate) / i.iteration
        }

        # update empirical covariance matrix
        if (adapting.shape >= 0) {
            tmp <- updateCovmat(covmat.empirical, theta.mean,
                                theta.current, i.iteration)
            covmat.empirical <- tmp$covmat
            theta.mean <- tmp$theta.mean
        }

    }

    return(list(trace = trace,
        acceptance.rate = acceptance.rate,
        covmat.empirical = covmat.empirical))
}
