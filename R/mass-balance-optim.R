#' Least square with mass balance penalty
#'
#' @param hat A vector of estimated flow in the transformed space.
#' @param obs A vector of observed flow in the transformed space.
#' @param lambda Penalty weight.
#' @param mus A vector of means, one for each target.
#' @param sigmas A vector of the standard deviations, one for each target.
#' @param log.seasons A vector containing the indices of the seasons that are log-transformed.
#' @param log.ann TRUE if the annual reconstruction is log-transformed.
#' @param N The number of targets (number of seasons plus one for the annual reconstruction).
#' @param sInd Indices of the seasons, i.e, 1...N-1
#' @return Objective function value: least squares plus a penalty term.
lsq_mb <- function(hat, obs, lambda, mus, sigmas, log.seasons, log.ann, N, sInd) {

  s1 <- sum((hat - obs)^2) # Regression part

  if (lambda == 0) {       # Penalty part
    s2 <- 0
  } else {

    # Convert to matrix
    # Use row form as rowUnscale is faster

    hatBack <- matrix(hat, nrow = N, byrow = TRUE)

    # Unscale for the seasons only
    if (!is.null(mus)) hatBack[sInd, ] <- rowUnscale(hatBack[sInd, ], mus[sInd], sigmas[sInd])

    # Take exponential where necessary
    hatBack[log.seasons, ] <- exp(hatBack[log.seasons, ])

    if (any(is.infinite(hatBack))) {
      s2 <- 1e12 # GA needs finite f value
    } else {
      # Take sum
      totalSeasonal <- colsums(hatBack[sInd, ])

      # Log-transform if necessary
      if (log.ann) totalSeasonal <- log(totalSeasonal)

      # Scale using the annual statistics
      if (!is.null(mus)) totalSeasonal <- (totalSeasonal - mus[N]) / sigmas[N]

      # Calculate penalty term in the z-score space
      s2 <- sum((totalSeasonal - hatBack[N, ])^2)
    }
  }
  s1 + lambda * s2
}

#' Objective function from parameters
#'
#' This is a wrapper for `lsq_mb()`. It first calculates `hat`, then calls `lsq_mb()`.
#' This is used in `optim()`, so it returns a scalar.
 #' @param beta Parameters
#' @param X Inputs, must have columns of 1 added
#' @param Y Observed Dry, Wet, and Annual log-transformed flows
#' @inheritParams lsq_mb
#' @return Objective function value
obj_fun <- function(beta, X, Y, lambda, mus, sigmas, log.seasons, log.ann, N, sInd) {

  hat <- X %*% beta
  lsq_mb(hat, Y, lambda, mus, sigmas, log.seasons, log.ann, N, sInd)
}

#' Fit parameters with mass balance criterion
#'
#' @inheritParams obj_fun
#' @return A one-column matrix of beta value
mb_fit <- function(X, Y, lambda, mus, sigmas, log.seasons, log.ann, N, sInd) {

  # Solve the free optimization and use the result as initial value L-BFGS-B search
  # This will speed up the search process
  XTX <- crossprod(X)
  XTY <- crossprod(X, Y)
  betaFree <- solve(XTX, XTY)

  # Solve the constrained optimization (with constraints changed to penalties)
  stats::optim(
    betaFree, obj_fun, method = 'L-BFGS-B',
    X = X, Y = Y, lambda = lambda,
    mus = mus, sigmas = sigmas,
    log.seasons = log.seasons, log.ann = log.ann, N = N, sInd = sInd)$par
}

#' Prepend a column of ones
#'
#' @param x The input matrix
#' @return x with a column of ones prepended, which is named 'Int' for 'intercept'
prepend_ones <- function(x) cbind('Int' = rep(1, dim(x)[1]), x)

#' Back-transformation
#'
#' Transform the reconstructed values back to the flow space
#' and convert to data.table
#' @param years A vector of all years in the study period
#' @param log.trans A vector containing the indices of the columns to be log-transformed.
#' @inheritParams lsq_mb
#' @param season.names A character vector containing the names of the seasons
#' @return A `data.table` with three columns: Q (the back-transformed streamflow), season, and year.
back_trans <- function(hat, years, mus, sigmas, log.trans, N, season.names) {

  # Here we use the column form because it's easier to do c() and we don't have to worry about speed
  hatBack <- matrix(hat, ncol = N)
  if (!is.null(mus)) hatBack <- colUnscale(hatBack, mus, sigmas)
  hatBack[, log.trans] <- exp(hatBack[, log.trans])

  data.table(
    Q = c(hatBack),
    season = rep(season.names, each = length(hat) / N),
    year = rep(years, N))
}

#' Mass-balance-adjusted reconstruction
#'
#' @param instQ Instrumental data, in the same order as pc.list. The "season" column must be a factor.
#' @param pc.list List of PC matrices. The first element is for the first season, second element for second season, and so on. The last element is for the annual reconstruction.
#' @param start.year The first year of record
#' @param lambda The penalty weight
#' @param log.trans A vector containing indices of the targets to be log-transformed. If no transformation is needed, provide `NULL`.
#' @param force.standardize If TRUE, all observations are standardized. See Details.
#' @return A `data.table` with the following columns: season, year, Q, and lambda.
#' @section Details:
#' If some targets are log transformed and some are not, they will have different scales, which affects the objective function. In this case the observations will be standardized so that they are in the same range. Otherwise, standardization are skipped for speed. However, in some cases you may want to standardize any ways, for example when flows in some months are much larger than in other months. In this case, set `force.standardize = TRUE`.
#' @examples
#' mb_reconstruction(p1Seasonal, pc3seasons, 1750, lambda = 1, log.trans = 1:3)
#' @export
mb_reconstruction <- function(instQ, pc.list, start.year, lambda = 1,
                              log.trans = NULL, force.standardize = FALSE) {

  # Setup
  years     <- start.year:max(instQ$year)
  instInd   <- which(years %in% instQ$year)
  seasons   <- levels(instQ$season)
  N         <- length(seasons)
  sInd      <- 1:(N-1)
  Y         <- instQ$Qa

  XList     <- lapply(pc.list, prepend_ones)
  XListInst <- lapply(XList, function(x) x[instInd, , drop = FALSE])
  X         <- as.matrix(.bdiag(XList))
  XTrain    <- as.matrix(.bdiag(XListInst))

  # NOTES:
  # Working with matrices are much faster than with data.table
  # Important to keep drop = FALSE; otherwise, when there is only one PC, a vector is returned.
  # Use column form so that we can use c() later

  # Calibration -------------------------------------

  if (is.null(log.trans)) {

    if (force.standardize) {

      # Scale the observation
      Y   <- matrix(Y, ncol = N)
      Y   <- colScale(Y)
      cm  <- attributes(Y)[['scaled:center']] # column mean
      csd <- attributes(Y)[['scaled:scale']]  # column sd
      Y   <- c(Y)

      # Multiply X by sigma_s / sigma_q before making A
      ratio   <- csd / csd[N]
      Xscaled <- lapply(sInd, function(k) XListInst[[k]] * ratio[k])
      A       <- cbind(do.call(cbind, Xscaled), -XListInst[[N]])
    } else {
      cm  <- NULL
      csd <- NULL
      A   <- cbind(do.call(cbind, XListInst[sInd]), -XListInst[[N]])
    }

    # Analytical solution when there is no transformation
    XTX  <- crossprod(XTrain)
    XTY  <- crossprod(XTrain, Y)
    ATA  <- crossprod(A)
    beta <- solve(XTX + lambda * ATA, XTY)

  } else {  # Numerical solution

    Y <- matrix(Y, ncol = N)
    Y[, log.trans] <- log(Y[, log.trans])
    if (length(log.trans) < N || force.standardize) {
      Y   <- colScale(Y)
      cm  <- attributes(Y)[['scaled:center']]
      csd <- attributes(Y)[['scaled:scale']]
    } else {
      cm  <- NULL
      csd <- NULL
    }
    Y <- c(Y)

    log.seasons <- which(log.trans < N)
    log.ann     <- max(log.trans) == N

    beta <- mb_fit(XTrain, Y, lambda, cm, csd, log.seasons, log.ann, N, sInd)
  }

  # Prediction ------------------------------------------

  hat <- X %*% beta
  DT <- back_trans(hat, years, cm, csd, log.trans, N, seasons)
  DT[, lambda := lambda][]
  setcolorder(DT, c('season', 'year', 'Q', 'lambda'))
  DT[]
}


#' Cross-validation
#'
#' @inheritParams mb_reconstruction
#' @param pc.list List of PC matrices
#' @param cv.folds A list containing the cross validation folds
#' @param return.type The type of results to be returned. Several types are possible to suit multiple use cases.
#' \describe{
#'   \item{`fval`}{Only the objective function value (penalized least squares) is returned; this is useful for the outer optimization for site selection.}
#'   \item{`metrics`}{all performance metrics are returned.}
#'   \item{`metric means`}{the Tukey's biweight robust mean of each metric is returned.}
#'   \item{`Q`}{The predicted flow in each cross-validation run is returned. This is the most basic output, so that you can use it to calculate other metrics that are not provided by the package.}
#' }
#' @return A `data.table` containing cross-validation results (metrics, fval, or metric means) for each target.
#' @examples
#' cvFolds <- make_Z(1922:2003, nRuns = 50, frac = 0.25, contiguous = TRUE)
#' cv <- cv_mb(p1Seasonal, pc3seasons, cvFolds, 1750, log.trans = 1:3, return.type = 'metrics')
#' @export
cv_mb <- function(instQ, pc.list, cv.folds, start.year,
                  lambda = 1,
                  log.trans = NULL, force.standardize = FALSE,
                  return.type = c('fval', 'metrics', 'metric means', 'Q')) {

  # Setup
  years     <- start.year:max(instQ$year)
  instInd   <- which(years %in% instQ$year)
  yearsInst <- years[instInd]
  seasons   <- levels(instQ$season)
  N         <- length(seasons)
  sInd      <- 1:(N-1)
  hasLog    <- !is.null(log.trans)
  hasScale  <- (hasLog && length(log.trans) < N) || force.standardize

  Y         <- instQ$Qa
  indMat    <- matrix(seq_along(Y), ncol = N)

  XListInst <- lapply(pc.list, function(x) prepend_ones(x[instInd, , drop = FALSE]))
  XTrain    <- as.matrix(.bdiag(XListInst))

  # To pass R CMD CHECK for NSE
  Q <- Qa <- season <- NULL

  # Cross-validation is trickier. We want to form the matrix and take log once before the CV runs
  # but the standardization needs to be done for each CV run
  # otherwise we have data leak.

  # We keep the YMat matrix so that we can subset during the routine instead of having
  # to make it repeatedly.

  if (hasLog) {

    log.seasons <- which(log.trans < N)
    log.ann     <- max(log.trans) == N

    YMat <- matrix(Y, ncol = N)
    YMat[, log.trans] <- log(YMat[, log.trans])

    if (hasScale) {
      Y   <- colScale(YMat)
      cm  <- attributes(Y)[['scaled:center']]
      csd <- attributes(Y)[['scaled:scale']]
      Y   <- c(Y)
    } else {
      # No scaling, just merge back the logged matrix
      Y   <- c(YMat)
      cm  <- NULL
      csd <- NULL
      Y   <- c(Y)
    }

  } else {
    log.seasons <- 0
    log.ann <- FALSE

    if (hasScale) {
      YMat <- matrix(Y, ncol = N)
      Y    <- colScale(YMat)
      cm   <- attributes(Y)[['scaled:center']]
      csd  <- attributes(Y)[['scaled:scale']]
      Y    <- c(Y)
    } else {
      # No log and no scale, don't do anything
      cm   <- NULL
      csd  <- NULL
      Araw <- cbind(do.call(cbind, XListInst[sInd]), -XListInst[[N]])
    }
  }

  # Cross-validation routine ------------------------------

  one_cv <- function(z) {

    # Indices on stacked form
    calInd <- c(indMat[-z, ])
    valInd <- c(indMat[ z, ])

    # Calibration
    # Make Y2 for calibration because we need to keep Y for validation.

    if (hasLog) {

      # Here YMat is already logged

      if (hasScale) { # hasLog and hasScale
        Y2  <- colScale(YMat[-z, ])
        cm  <- attributes(Y2)[['scaled:center']]
        csd <- attributes(Y2)[['scaled:scale']]
        Y2  <- c(Y2)
      } else {  # hasLog but no scale
        Y2   <- Y[calInd]
        cm   <- NULL
        csd  <- NULL
      }

      beta <- mb_fit(XTrain[calInd, ], Y2, lambda, cm, csd, log.seasons, log.ann, N, sInd)

    } else {

      # Here YMat is not logged

      if (hasScale) { # hasScale but no log

        Y2  <- colScale(YMat[-z, ])
        cm  <- attributes(Y2)[['scaled:center']]
        csd <- attributes(Y2)[['scaled:scale']]
        Y2  <- c(Y2)

        ratio   <- csd / csd[N]
        Xscaled <- lapply(sInd, function(k) XListInst[[k]][-z, ] * ratio[k])
        Acal    <- cbind(do.call(cbind, Xscaled), -XListInst[[N]][-z, ])
      } else {
        Y2   <- Y[calInd]
        cm   <- NULL
        csd  <- NULL
        Acal <- Araw[-z, ]
      }

      XTX <- crossprod(XTrain[calInd, ])
      XTY <- crossprod(XTrain[calInd, ], Y2)
      ATA <- crossprod(Acal)
      beta <- solve(XTX + lambda * ATA, XTY)
    }

    # Validation

    hat <- XTrain %*% beta # All instrumental period prediction

    fval <- lsq_mb(hat[valInd], Y[valInd], lambda, cm, csd, log.seasons, log.ann, N, sInd)

    if (return.type == 'fval') {
      ans <- fval
    } else {
      Qcv <- merge(
        back_trans(hat, yearsInst, cm, csd, log.trans, N, seasons),
        instQ, by = c('year', 'season'))
      if (return.type == 'Q') {
        ans <- Qcv
      } else { # Metrics
        metrics <- Qcv[, as.data.table(t(calculate_metrics(Q, Qa, z))), by = season]
        metrics[, fval := fval, by = season]
        ans <- metrics
      }
    }
    ans
  }

  # Run cv ---------------------------------------------------

  if (return.type == 'fval') { # A vector of fval
    out <- unlist(lapply(cv.folds, one_cv), use.names = FALSE)
  } else { # A data.table of all metrics or all reps
    outReps <- rbindlist(lapply(cv.folds, one_cv), idcol = 'rep')
    if (return.type == 'metric means') {
      out <- outReps[, lapply(.SD, tbrm), .SDcols = c('R2', 'RE', 'CE', 'nRMSE', 'KGE'), by = season]
    } else out <- outReps
    out[, season := factor(season, seasons)]
    out <- out[order(season)]
  }
  out
}

