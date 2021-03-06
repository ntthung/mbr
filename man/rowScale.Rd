% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/R-utils.R
\name{rowScale}
\alias{rowScale}
\title{Scale rows of a Matrix}
\usage{
rowScale(x, add_attr = TRUE)
}
\arguments{
\item{x}{A matrix.}

\item{add_attr}{If TRUE, the column means and standard deviations are returned as attributes. This is consistent with \code{\link[base:scale]{base::scale()}}.}
}
\value{
The scaled matrix.
}
\description{
Similar to \link{colScale}
}
