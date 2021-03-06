#' Create a summary of a fitted model represented by a \code{brmsfit} object
#'
#' @param object An object of class \code{brmsfit}
#' @param priors Logical; Indicating if priors should be included 
#'   in the summary. Default is \code{FALSE}.
#' @param prob A value between 0 and 1 indicating the desired probability 
#'   to be covered by the uncertainty intervals. The default is 0.95.
#' @param mc_se Logical; Indicating if the uncertainty caused by the 
#'   MCMC sampling should be shown in the summary. Defaults to \code{FALSE}.
#' @param ... Other potential arguments
#' 
#' @details The convergence diagnostics \code{Rhat}, \code{Bulk_ESS}, and 
#' \code{Tail_ESS} are described in detail in Vehtari et al. (2019).
#' 
#' @references 
#' Aki Vehtari, Andrew Gelman, Daniel Simpson, Bob Carpenter, and
#' Paul-Christian Bürkner (2019). Rank-normalization, folding, and
#' localization: An improved R-hat for assessing convergence of
#' MCMC. *arXiv preprint* `arXiv:1903.08008`.
#' 
#' @method summary brmsfit
#' @importMethodsFrom rstan summary
#' @export
summary.brmsfit <- function(object, priors = FALSE, prob = 0.95,
                            mc_se = FALSE, ...) {
  priors <- as_one_logical(priors)
  prob <- as_one_numeric(prob)
  if (prob < 0 || prob > 1) {
    stop2("'prob' must be a single numeric value in [0, 1].")
  }
  mc_se <- as_one_logical(mc_se)
  if (mc_se) {
    warning2("Argument 'mc_se' is currently deactivated but ", 
             "will be working again in the future. Sorry!")
  }
  
  object <- restructure(object)
  bterms <- parse_bf(object$formula)
  out <- list(
    formula = object$formula,
    data.name = object$data.name, 
    group = unique(object$ranef$group), 
    nobs = nobs(object), 
    ngrps = ngrps(object), 
    autocor = object$autocor,
    prior = empty_prior(),
    algorithm = algorithm(object)
  )
  class(out) <- "brmssummary"
  if (!length(object$fit@sim)) {
    # the model does not contain posterior samples
    return(out)
  }
  out$chains <- object$fit@sim$chains
  out$iter <- object$fit@sim$iter
  out$warmup <- object$fit@sim$warmup
  out$thin <- object$fit@sim$thin
  stan_args <- object$fit@stan_args[[1]]
  out$sampler <- paste0(stan_args$method, "(", stan_args$algorithm, ")")
  if (priors) {
    out$prior <- prior_summary(object, all = FALSE)
  }
  
  # compute a summary for given set of parameters
  .summary <- function(object, pars, prob) {
    # TODO: use rstan::monitor instead once it is clean and stable
    sims <- as.array(object, pars = pars, fixed = TRUE)
    parnames <- dimnames(sims)[[3]]
    probs <- c((1 - prob) / 2, 1 - (1 - prob) / 2)
    valid <- rep(NA, length(parnames))
    out <- named_list(parnames)
    for (i in seq_along(out)) {
      sims_i <- sims[, , i]
      valid[i] <- all(is.finite(sims_i))
      quan <- unname(quantile(sims_i, probs = probs))
      mean <- mean(sims_i)
      sd <- sd(sims_i)
      rhat <- rstan::Rhat(sims_i)
      ess_bulk <- round(rstan::ess_bulk(sims_i))
      ess_tail <- round(rstan::ess_tail(sims_i))
      out[[i]] <- c(mean, sd, quan, rhat, ess_bulk, ess_tail)
    }
    out <- do_call(rbind, out)
    CIs <- paste0(c("l-", "u-"), prob * 100, "% CI")
    # TODO: align column names with summary outputs of other methods
    colnames(out) <- c(
      "Estimate", "Est.Error", CIs, "Rhat", "Bulk_ESS", "Tail_ESS"
    )
    rownames(out) <- parnames
    S <- prod(dim(sims)[1:2])
    out[valid & !is.finite(out[, "Rhat"]), "Rhat"] <- 1
    out[valid & !is.finite(out[, "Bulk_ESS"]), "Bulk_ESS"] <- S
    out[valid & !is.finite(out[, "Tail_ESS"]), "Tail_ESS"] <- S
    return(out)
  }
  
  pars <- parnames(object)
  excl_regex <- "^(r|s|z|zs|zgp|Xme|L|Lrescor|prior|lp)(_|$)"
  pars <- pars[!grepl(excl_regex, pars)]
  fit_summary <- .summary(object, pars = pars, prob = prob)
  if (algorithm(object) == "sampling") {
    Rhats <- fit_summary[, "Rhat"]
    if (any(Rhats > 1.05, na.rm = TRUE)) {
      warning2(
        "Parts of the model have not converged (some Rhats are > 1.05). ",
        "Be careful when analysing the results! We recommend running ", 
        "more iterations and/or setting stronger priors."
      )
    }
    div_trans <- sum(nuts_params(object, pars = "divergent__")$Value)
    adapt_delta <- control_params(object)$adapt_delta
    if (div_trans > 0) {
      warning2(
        "There were ", div_trans, " divergent transitions after warmup. ", 
        "Increasing adapt_delta above ", adapt_delta, " may help. See ",
        "http://mc-stan.org/misc/warnings.html#divergent-transitions-after-warmup"
      )
    }
  }
  
  # summary of population-level effects
  fe_pars <- pars[grepl(fixef_pars(), pars)]
  out$fixed <- fit_summary[fe_pars, , drop = FALSE]
  rownames(out$fixed) <- gsub(fixef_pars(), "", fe_pars)
  
  # summary of family specific parameters
  spec_pars <- c(valid_dpars(object), "delta")
  spec_pars <- paste0(spec_pars, collapse = "|")
  spec_pars <- paste0("^(", spec_pars, ")($|_)")
  spec_pars <- pars[grepl(spec_pars, pars)]
  out$spec_pars <- fit_summary[spec_pars, , drop = FALSE]
  
  # summary of residual correlations
  rescor_pars <- pars[grepl("^rescor_", pars)]
  if (length(rescor_pars)) {
    out$rescor_pars <- fit_summary[rescor_pars, , drop = FALSE]
    rescor_pars <- sub("__", ",", sub("__", "(", rescor_pars))
    rownames(out$rescor_pars) <- paste0(rescor_pars, ")")
  }
  
  # summary of autocorrelation effects
  cor_pars <- pars[grepl(regex_autocor_pars(), pars)]
  out$cor_pars <- fit_summary[cor_pars, , drop = FALSE]
  rownames(out$cor_pars) <- cor_pars
  
  # summary of group-level effects
  for (g in out$group) {
    gregex <- escape_dot(g)
    sd_prefix <- paste0("^sd_", gregex, "__")
    sd_pars <- pars[grepl(sd_prefix, pars)]
    cor_prefix <- paste0("^cor_", gregex, "__")
    cor_pars <- pars[grepl(cor_prefix, pars)]
    df_prefix <- paste0("^df_", gregex, "$")
    df_pars <- pars[grepl(df_prefix, pars)]
    gpars <- c(df_pars, sd_pars, cor_pars)
    out$random[[g]] <- fit_summary[gpars, , drop = FALSE]
    if (has_rows(out$random[[g]])) {
      sd_names <- sub(sd_prefix, "sd(", sd_pars)
      cor_names <- sub(cor_prefix, "cor(", cor_pars)
      cor_names <- sub("__", ",", cor_names)
      df_names <- sub(df_prefix, "df", df_pars)
      gnames <- c(df_names, paste0(c(sd_names, cor_names), ")"))
      rownames(out$random[[g]]) <- gnames
    }
  }
  # summary of smooths
  sm_pars <- pars[grepl("^sds_", pars)]
  if (length(sm_pars)) {
    out$splines <- fit_summary[sm_pars, , drop = FALSE]
    rownames(out$splines) <- paste0(gsub("^sds_", "sds(", sm_pars), ")")
  }
  # summary of monotonic parameters
  mo_pars <- pars[grepl("^simo_", pars)]
  if (length(mo_pars)) {
    out$mo <- fit_summary[mo_pars, , drop = FALSE]
    rownames(out$mo) <- gsub("^simo_", "", mo_pars)
  }
  # summary of gaussian processes
  gp_pars <- pars[grepl("^(sdgp|lscale)_", pars)]
  if (length(gp_pars)) {
    out$gp <- fit_summary[gp_pars, , drop = FALSE]
    rownames(out$gp) <- gsub("^sdgp_", "sdgp(", rownames(out$gp))
    rownames(out$gp) <- gsub("^lscale_", "lscale(", rownames(out$gp))
    rownames(out$gp) <- paste0(rownames(out$gp), ")")
  }
  out
}

#' Print a summary for a fitted model represented by a \code{brmsfit} object
#' 
#' @aliases print.brmssummary
#' 
#' @param x An object of class \code{brmsfit}
#' @param digits The number of significant digits for printing out the summary; 
#'  defaults to 2. The effective sample size is always rounded to integers.
#' @param ... Additional arguments that would be passed 
#'  to method \code{summary} of \code{brmsfit}.
#' 
#' @seealso \code{\link{summary.brmsfit}}
#' 
#' @export
print.brmsfit <- function(x, digits = 2, ...) {
  print(summary(x, ...), digits = digits, ...)
}

#' @export
print.brmssummary <- function(x, digits = 2, ...) {
  cat(" Family: ")
  cat(summarise_families(x$formula), "\n")
  cat("  Links: ")
  cat(summarise_links(x$formula, wsp = 9), "\n")
  cat("Formula: ")
  print(x$formula, wsp = 9)
  cat(paste0(
    "   Data: ", x$data.name, 
    " (Number of observations: ", x$nobs, ") \n"
  ))
  if (!isTRUE(nzchar(x$sampler))) {
    cat("\nThe model does not contain posterior samples.\n")
  } else {
    final_samples <- ceiling((x$iter - x$warmup) / x$thin * x$chains)
    cat(paste0(
      "Samples: ", x$chains, " chains, each with iter = ", x$iter, 
      "; warmup = ", x$warmup, "; thin = ", x$thin, ";\n",
      "         total post-warmup samples = ", final_samples, "\n\n"
    ))
    if (nrow(x$prior)) {
      cat("Priors: \n")
      print(x$prior, show_df = FALSE)
      cat("\n")
    }
    if (length(x$splines)) {
      cat("Smooth Terms: \n")
      print_format(x$splines, digits)
      cat("\n")
    }
    if (length(x$gp)) {
      cat("Gaussian Process Terms: \n")
      print_format(x$gp, digits)
      cat("\n")
    }
    if (nrow(x$cor_pars)) {
      cat("Correlation Structures:\n")
      # TODO: better printing for correlation structures?
      print_format(x$cor_pars, digits)
      cat("\n")
    }
    if (length(x$random)) {
      cat("Group-Level Effects: \n")
      for (i in seq_along(x$random)) {
        g <- names(x$random)[i]
        cat(paste0("~", g, " (Number of levels: ", x$ngrps[[g]], ") \n"))
        print_format(x$random[[g]], digits)
        cat("\n")
      }
    }
    if (nrow(x$fixed)) {
      cat("Population-Level Effects: \n")
      print_format(x$fixed, digits)
      cat("\n")
    }
    if (length(x$mo)) {
      cat("Simplex Parameters: \n")
      print_format(x$mo, digits)
      cat("\n")
    }
    if (nrow(x$spec_pars)) {
      cat("Family Specific Parameters: \n")
      print_format(x$spec_pars, digits)
      cat("\n")
    }
    if (length(x$rescor_pars)) {
      cat("Residual Correlations: \n")
      print_format(x$rescor, digits)
      cat("\n")
    }
    cat(paste0("Samples were drawn using ", x$sampler, ". "))
    if (x$algorithm == "sampling") {
      cat(paste0(
        "For each parameter, Bulk_ESS\n",
        "and Tail_ESS are effective sample size measures, ",
        "and Rhat is the potential\n", 
        "scale reduction factor on split chains ",
        "(at convergence, Rhat = 1)."
      ))
    }
    cat("\n")
  }
  invisible(x)
}

# helper function to print summary matrices in nice format
# also displays -0.00 as a result of round negative values to zero (#263)
# @param x object to be printed; coerced to matrix
# @param digits number of digits to show
# @param no_digits names of columns for which no digits should be shown
print_format <- function(x, digits = 2, no_digits = c("Bulk_ESS", "Tail_ESS")) {
  x <- as.matrix(x)
  digits <- as.numeric(digits)
  if (length(digits) != 1L) {
    stop2("'digits' should be a single numeric value.")
  }
  out <- x
  fmt <- paste0("%.", digits, "f")
  for (i in seq_cols(x)) {
    if (isTRUE(colnames(x)[i] %in% no_digits)) {
      out[, i] <- sprintf("%.0f", x[, i])
    } else {
      out[, i] <- sprintf(fmt, x[, i])
    }
  }
  print(out, quote = FALSE, right = TRUE)
  invisible(x)
}

# regex to extract population-level coefficients
fixef_pars <- function() {
  types <- c("", "s", "cs", "sp", "mo", "me", "mi", "m")
  types <- paste0("(", types, ")", collapse = "|")
  paste0("^b(", types, ")_")
}

# algorithm used in the model fitting
algorithm <- function(x) {
  stopifnot(is.brmsfit(x))
  if (is.null(x$algorithm)) "sampling"
  else x$algorithm
}

#' Summarize Posterior Samples
#' 
#' Summarizes posterior samples based on point estimates (mean or median),
#' estimation errors (SD or MAD) and quantiles.
#' 
#' @param x An \R object.
#' @param probs The percentiles to be computed by the 
#'   \code{quantile} function.
#' @param robust If \code{FALSE} (the default) the mean is used as 
#'  the measure of central tendency and the standard deviation as 
#'  the measure of variability. If \code{TRUE}, the median and the 
#'  median absolute deviation (MAD) are applied instead.
#' @param ... More arguments passed to or from other methods.
#' @inheritParams posterior_samples
#' 
#' @return A matrix where rows indicate parameters 
#'  and columns indicate the summary estimates.
#'  
#' @examples 
#' \dontrun{
#' fit <- brm(time ~ age * sex, data = kidney)
#' posterior_summary(fit)
#' }
#' 
#' @export
posterior_summary <- function(x, ...) {
  UseMethod("posterior_summary")
}

#' @rdname posterior_summary
#' @export
posterior_summary.default <- function(x, probs = c(0.025, 0.975), 
                                      robust = FALSE, ...) {
  if (!length(x)) {
    stop2("No posterior samples supplied.")
  }
  if (robust) {
    coefs <- c("median", "mad", "quantile")
  } else {
    coefs <- c("mean", "sd", "quantile")
  }
  .posterior_summary <- function(x) {
    do_call(cbind, lapply(
      coefs, get_estimate, samples = x, 
      probs = probs, na.rm = TRUE
    ))
  }
  if (length(dim(x)) <= 2L) {
    # data.frames cause trouble in as.array
    x <- as.matrix(x)
  } else {
    x <- as.array(x) 
  }
  if (length(dim(x)) == 2L) {
    out <- .posterior_summary(x)
    rownames(out) <- colnames(x)
  } else if (length(dim(x)) == 3L) {
    out <- lapply(array2list(x), .posterior_summary)
    out <- abind(out, along = 3)
    dnx <- dimnames(x)
    dimnames(out) <- list(dnx[[2]], dimnames(out)[[2]], dnx[[3]])
  } else {
    stop("'x' must be of dimension 2 or 3.")
  }
  colnames(out) <- c("Estimate", "Est.Error", paste0("Q", probs * 100))
  out  
}

#' @rdname posterior_summary
#' @export
posterior_summary.brmsfit <- function(x, pars = NA, 
                                      probs = c(0.025, 0.975), 
                                      robust = FALSE, ...) {
  out <- as.matrix(x, pars = pars, ...)
  posterior_summary(out, probs = probs, robust = robust, ...)
}

# calculate estimates over posterior samples 
# @param coef coefficient to be applied on the samples (e.g., "mean")
# @param samples the samples over which to apply coef
# @param margin see 'apply'
# @param ... additional arguments passed to get(coef)
# @return typically a matrix with colnames(samples) as colnames
get_estimate <- function(coef, samples, margin = 2, ...) {
  dots <- list(...)
  args <- list(X = samples, MARGIN = margin, FUN = coef)
  fun_args <- names(formals(coef))
  if (!"..." %in% fun_args) {
    dots <- dots[names(dots) %in% fun_args]
  }
  x <- do_call(apply, c(args, dots))
  if (is.null(dim(x))) {
    x <- matrix(x, dimnames = list(NULL, coef))
  } else if (coef == "quantile") {
    x <- aperm(x, length(dim(x)):1)
  }
  x 
}

#' Table Creation for Posterior Samples
#' 
#' Create a table for unique values of posterior samples. 
#' This is usually only useful when summarizing predictions 
#' of ordinal models.
#' 
#' @param x A matrix of posterior samples where rows 
#'   indicate samples and columns indicate parameters. 
#' @param levels Optional values of possible posterior values.
#'   Defaults to all unique values in \code{x}.
#' 
#' @return A matrix where rows indicate parameters 
#'  and columns indicate the unique values of 
#'  posterior samples.
#'  
#' @examples 
#' \dontrun{
#' fit <- brm(rating ~ period + carry + treat, 
#'            data = inhaler, family = cumulative())
#' pr <- predict(fit, summary = FALSE)
#' posterior_table(pr)
#' }
#'  
#' @export
posterior_table <- function(x, levels = NULL) {
  x <- as.matrix(x)
  if (anyNA(x)) {
    warning2("NAs will be ignored in 'posterior_table'.")
  }
  if (is.null(levels)) {
    levels <- sort(unique(as.vector(x)))
  }
  xlevels <- attr(x, "levels")
  if (length(xlevels) != length(levels)) {
    xlevels <- levels
  }
  out <- lapply(seq_len(ncol(x)), 
    function(n) table(factor(x[, n], levels = levels))
  )
  out <- do_call(rbind, out)
  # compute relative frequencies
  out <- out / rowSums(out)
  rownames(out) <- colnames(x)
  colnames(out) <- paste0("P(Y = ", xlevels, ")")
  out
}

#' Compute posterior uncertainty intervals 
#' 
#' Compute posterior uncertainty intervals for \code{brmsfit} objects.
#' 
#' @inheritParams summary.brmsfit
#' @param pars Names of parameters for which posterior samples should be 
#'   returned, as given by a character vector or regular expressions. 
#'   By default, all posterior samples of all parameters are extracted.
#' @param ... More arguments passed to 
#'   \code{\link[brms:as.matrix.brmsfit]{as.matrix.brmsfit}}.
#' 
#' @return A \code{matrix} with lower and upper interval bounds
#'   as columns and as many rows as selected parameters.
#'   
#' @examples 
#' \dontrun{
#' fit <- brm(count ~ zAge + zBase * Trt,
#'            data = epilepsy, family = negbinomial())
#' posterior_interval(fit)
#' }
#' 
#' @aliases posterior_interval
#' @method posterior_interval brmsfit
#' @export
#' @export posterior_interval
#' @importFrom rstantools posterior_interval
posterior_interval.brmsfit <- function(
  object, pars = NA, prob = 0.95, ...
) {
  ps <- as.matrix(object, pars = pars, ...)
  rstantools::posterior_interval(ps, prob = prob)
}

#' Extract Priors of a Bayesian Model Fitted with \pkg{brms}
#' 
#' @aliases prior_summary
#' 
#' @param object A \code{brmsfit} object
#' @param all Logical; Show all parameters in the model which may have 
#'   priors (\code{TRUE}) or only those with proper priors (\code{FALSE})?
#' @param ... Further arguments passed to or from other methods.
#' 
#' @return For \code{brmsfit} objects, an object of class \code{brmsprior}.
#' 
#' @examples 
#' \dontrun{
#' fit <- brm(count ~ zAge + zBase * Trt  
#'              + (1|patient) + (1|obs), 
#'            data = epilepsy, family = poisson(), 
#'            prior = c(prior(student_t(5,0,10), class = b),
#'                      prior(cauchy(0,2), class = sd)))
#'                    
#' prior_summary(fit)
#' prior_summary(fit, all = FALSE)
#' print(prior_summary(fit, all = FALSE), show_df = FALSE)
#' }
#' 
#' @method prior_summary brmsfit
#' @export
#' @export prior_summary
#' @importFrom rstantools prior_summary
prior_summary.brmsfit <- function(object, all = TRUE, ...) {
  object <- restructure(object)
  prior <- object$prior
  if (!all) {
    prior <- prior[nzchar(prior$prior), ]
  }
  prior
}
