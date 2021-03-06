#' Simulate forward a stochastic model
#'
#' This function uses the function \code{\link[adaptivetau]{ssa.adaptivetau}} to simulate the model and returns the trajectories in a valid format for the class \code{\link{fitmodel}}.
#' @param theta named vector of model parameters.
#' @param init.state named vector of initial state of the model.
#' @param times time sequence for which state of the model is wanted; the first value of times must be the initial time.
#' @inheritParams adaptivetau::ssa.adaptivetau
#' @export
#' @import adaptivetau
#' @return a data.frame of dimension \code{length(times)x(length(init.state)+1)} with column names equal to \code{c("time",names(init.state))}.
simulateModelStochastic <- function(theta,init.state,times,transitions,rateFunc) {


    stoch <- as.data.frame(ssa.adaptivetau(init.state,transitions,rateFunc,theta,tf=diff(range(times))))

    # rescale time as absolute value
    stoch$time <- stoch$time + min(times)

    # interpolate
    traj <- cbind(time=times,apply(stoch[,-1],2,function(col){approx(x=stoch[,1],y=col,xout=times,method="constant")$y}))

    return(as.data.frame(traj))

}



#'Simulate several replicate of the model
#'
#'Simulate several replicate of a fitmodel using its function simulate
#' @param times vector of times at which you want to observe the states of the model.
#' @param n number of replicated simulations.
#' @param observation logical, if \code{TRUE} simulated observation are generated by \code{rTrajObs}.
#' @inheritParams testFitmodel
#' @export
#' @import plyr
#' @return a data.frame of dimension \code{[nxlength(times)]x[length(init.state)+2]} with column names equal to \code{c("replicate","time",names(init.state))}.
simulateModelReplicates <- function(fitmodel,theta, init.state, times, n, observation=FALSE) {

    stopifnot(inherits(fitmodel,"fitmodel"),n>0)

    if(observation && is.null(fitmodel$dPointObs)){
        stop("Can't generate observation as ",sQuote("fitmodel")," doesn't have a ",sQuote("dPointObs")," function.")
    }

    rep <- as.list(1:n)
    names(rep) <- rep

    if (n > 1) {
        progress = "text"
    } else {
        progress = "none"
    }

    traj.rep <- ldply(rep,function(x) {

    if(observation){
            traj <- rTrajObs(fitmodel, theta, init.state, times)
        } else {
            traj <- fitmodel$simulate(theta,init.state,times)
        }

        return(traj)

    },.progress=progress,.id="replicate")

    return(traj.rep)
}


#'Simulate model until extinction
#'
#'Return final state at extinction
#' @param extinct character vetor. Simulations stop when all these state are extinct.
#' @param time.init numeric. Start time of simulation.
#' @param time.step numeric. Time step at which extinction is checked
#' @inheritParams testFitmodel
#' @inheritParams simulateModelReplicates
#' @inheritParams particleFilter
#' @export
#' @import plyr parallel doParallel
simulateFinalStateAtExtinction <- function(fitmodel, theta, init.state, extinct=NULL ,time.init=0, time.step=100, n=100, observation=FALSE, n.cores = 1) {

    stopifnot(inherits(fitmodel,"fitmodel"),n>0)

    if(observation && is.null(fitmodel$dPointObs)){
        stop("Can't generate observation as ",sQuote("fitmodel")," doesn't have a ",sQuote("dPointObs")," function.")
    }

    if(is.null(n.cores)){
        n.cores <- detectCores()
    }

    if(n.cores > 1){
        registerDoParallel(cores=n.cores)
    }

    rep <- as.list(1:n)
    names(rep) <- rep

    if (n > 1 && n.cores==1) {
        progress = "text"
    } else {
        progress = "none"
    }

    times <- c(time.init, time.step)

    final.state.rep <- ldply(rep,function(x) {

        if(observation){
            traj <- rTrajObs(fitmodel, theta, init.state, times)
        } else {
            traj <- fitmodel$simulate(theta,init.state,times)
        }

        current.state <- unlist(traj[nrow(traj),fitmodel$state.names])
        current.time <- last(traj$time)
        
        while(any(current.state[extinct]>=0.5)){

            times <- times + current.time

            if(observation){
                traj <- rTrajObs(fitmodel, theta, current.state, times)
            } else {
                traj <- fitmodel$simulate(theta, current.state,times)
            }

            current.state <- unlist(traj[nrow(traj),fitmodel$state.names])
            current.time <- last(traj$time)
        }

        return(data.frame(t(c(time=current.time,current.state))))

    },.progress=progress,.id="replicate",.parallel=(n.cores > 1),.paropts=list(.inorder=FALSE))

    return(final.state.rep)
}


#'Update covariance matrix
#'
#'Update covariance matrix using a stable one-pass algorithm. This is much more efficient than using \code{\link{cov}} on the full data.
#' @param covmat covariance matrix at iteration \code{i-1}. Must be numeric, symmetrical and named.
#' @param theta.mean mean vector at iteration \code{i-1}. Must be numeric and named.
#' @param theta vector of new value at iteration \code{i}. Must be numeric and named.
#' @param i current iteration.
#' @references \url{http://en.wikipedia.org/wiki/Algorithms\%5Ffor\%5Fcalculating\%5Fvariance#Covariance}
#' @export
#' @keywords internal
#' @return A list of two elements
#' \itemize{
#' \item \code{covmat} update covariance matrix
#' \item \code{theta.mean} updated mean vector
#' }
updateCovmat <- function(covmat,theta.mean,theta,i) {

    if(is.null(names(theta))){
        stop("Argument ",sQuote("theta")," must be named.",.call=FALSE)
    }
    if(is.null(names(theta.mean))){
        stop("Argument ",sQuote("theta.mean")," must be named.",.call=FALSE)
    }
    if(is.null(rownames(covmat))){
        stop("Argument ",sQuote("covmat")," must have named rows.",.call=FALSE)
    }
    if(is.null(colnames(covmat))){
        stop("Argument ",sQuote("covmat")," must have named columns.",.call=FALSE)
    }

    covmat <- covmat[names(theta),names(theta)]
    theta.mean <- theta.mean[names(theta)]

    residual <- as.vector(theta-theta.mean)
    covmat <- (covmat*(i-1)+(i-1)/i*residual%*%t(residual))/i
    theta.mean <- theta.mean + residual/i

    return(list(covmat=covmat,theta.mean=theta.mean))
}



#'Burn and thin MCMC chain
#'
#'Return a burned and thined trace of the chain.
#' @param trace either a \code{data.frame} or a \code{list} of \code{data.frame} with all variables in column, as outputed by \code{\link{mcmcMH}}. Accept also an \code{mcmc} or \code{mcmc.list} object.
#' @param burn proportion of the chain to burn.
#' @param thin number of samples to discard per sample that is being kept
#' @export
#' @import coda
#' @return an object with the same format as \code{trace} (\code{data.frame} or \code{list} of \code{data.frame} or \code{mcmc} object or \code{mcmc.list} object)
burnAndThin <- function(trace, burn = 0, thin = 0) {

    convert_to_mcmc <- FALSE

    if(class(trace)=="mcmc"){
        convert_to_mcmc <- TRUE
        trace <- as.data.frame(trace)
    } else if(class(trace)=="mcmc.list"){
        convert_to_mcmc <- TRUE
        trace <- as.list(trace)
    }

    if(is.data.frame(trace) || is.matrix(trace)){

        # remove burn
        if (burn > 0) {
            trace <- trace[-(1:burn), ]
        }
        # thin
        trace <- trace[seq(1, nrow(trace), thin + 1), ]

        if(convert_to_mcmc){
            trace <- mcmc(trace)
        }

    } else {

        trace <- lapply(trace, function(x) {

            # remove burn
            if (burn > 0) {
                x <- x[-(1:burn), ]
            }
            # thin
            x <- x[seq(1, nrow(x), thin + 1), ]

            if(convert_to_mcmc){
                x <- mcmc(x)
            }

            return(x)
        }) 

        if(convert_to_mcmc){
            trace <- mcmc.list(trace)            
        }
    }

    return(trace)
}


#'Distance weighted by number of oscillations
#'
#'This positive distance is the mean squared differences between \code{x} and the \code{y}, divided by the square of the number of times the \code{x} oscillates around the \code{y} (see note below for illustration).
#' @param x,y numeric vectors of the same length.
#' @note To illustrate this distance, suppose we observed a time series \code{y = c(1,3,5,7,5,3,1)} and we have two simulated time series \code{x1 = (3,5,7,9,7,5,3)} and \code{x2 = (3,5,3,5,7,5,3)}; \code{x1} is consistently above \code{y} and \code{x2} oscillates around \code{y}. While the squared differences are the same, we obtain \eqn{d(y, x1) = 4} and \eqn{d(y, x2) = 1.3}.
#' @export
distanceOscillation <- function(x, y) {

    # check x and y have same length
    if(length(x)!=length(y)){
        stop(sQuote("x")," and ",sQuote("y")," must be vector of the same length")
    }

    # 1 + number of times x oscillates around y
    n.oscillations <- 1+length(which(diff((x-y)>0)!=0))

    dist <- sum((x-y)^2)/(length(x)*n.oscillations)

    return(dist)
}


#'Export trace in Tracer format
#'
#'Print \code{trace} in a \code{file} that can be read by the software Tracer.
#' @param trace a \code{data.frame} with one column per estimated parameter, as returned by \code{\link{burnAndThin}}
#' @inheritParams utils::write.table
#' @note Tracer is a program for analysing the trace files generated by Bayesian MCMC runs. It can be dowloaded at \url{http://tree.bio.ed.ac.uk/software/tracer}.
#' @export
#' @seealso burnAndThin
#' @keywords internal
export2Tracer <- function(trace, file) {

    if(is.mcmc(trace)){
        trace <- as.data.frame(trace)
    }

    if(!"iteration"%in%names(trace)){
        trace$iteration <- (1:nrow(trace) - 1)
    }

    trace <- trace[c("iteration",setdiff(names(trace),c("iteration","weight")))]
    write.table(trace,file=file,quote=FALSE,row.names=FALSE,sep="\t")

}


#'Print named vector
#'
#'Print named vector with format specified by \code{fmt} (2 decimal places by default).
#' @param x named vector
#' @inheritParams base::sprintf
#' @inheritParams base::paste
#' @export
#' @seealso \code{\link[base]{sprintf}}
#' @keywords internal
printNamedVector <- function(x, fmt="%.2f", sep=" | ") {

    paste(paste(names(x),sprintf(fmt,x),sep=" = "),collapse=sep)

}



