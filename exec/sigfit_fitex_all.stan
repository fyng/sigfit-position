functions {
    // #include "common_functions.stan"
    vector scale_to_sum_1(vector v) {
        return (v / sum(v));
    }

    row_vector scale_row_to_sum_1(row_vector r) {
        return (r / sum(r));
    }

    /**
       * Copy an array of equal-length vectors (or simplexes)
       * into a matrix
       *
       * @param x An array of vectors
       * @return A matrix copy of x
       */
    matrix array_to_matrix(vector[] x) {
        // Assume x doesn't have 0 rows or columns
        matrix[size(x), rows(x[1])] y;
        for (m in 1:size(x))
            y[m] = x[m]';
        return y;
    }
}

data {
    int<lower=1, upper=3> family;  // model: 1=multinomial, 2=poisson, 3=normal
    int<lower=0, upper=1> robust;  // robust model: 0=no, 1=yes (neg binomial or t)
    int<lower=1> C;                // number of mutation categories
    int<lower=1> S;                // number of fixed signatures
    int<lower=1> G;                // number of genomes
    int<lower=1> N;                // number of extra signatures
    matrix[S, C] fixed_sigs;       // matrix of signatures (rows) by categories (columns)
    int counts_int[G, C];          // observed mutation counts (discrete case)
    real counts_real[G, C];        // observed mutation counts (continuous case)
    matrix[G, C] opportunities;    // mutational opportunities (genome per row)
    vector<lower=0>[S+N] kappa;    // prior on exposures (mixing proportions)
    matrix[N, C] alpha;            // prior for extra signatures
}

transformed data {
    // Dynamic dimensions for model-specific parameters:
    // unused parameters have zero length
    int C_phi = ((family == 2) && (robust == 1)) ? C : 0;
    int C_nu = ((family == 3) && (robust == 1)) ? C : 0;
    int G_sigma = (family == 3) ? G : 0;
    int G_mult = (family != 1) ? G : 0;

    int T = S + N;  // total number of signatures
}

parameters {
    simplex[C] extra_sigs[N];          // additional signatures to extract
    simplex[T] exposures[G];           // signature exposures (genome per row)
    real<lower=0> multiplier[G_mult];  // exposure multipliers
    vector<lower=0>[G_sigma] sigma;    // standard deviations (normal/t model)
    vector<lower=1>[C_nu] nu;          // degrees of freedom (t model)
    vector<lower=0>[C_phi] phi_raw;    // unscaled overdispersions (neg bin model)
}

transformed parameters {
    matrix<lower=0>[G, T] activities;  // scaled exposures (# mutations)
    matrix[G, C] expected_counts;
    matrix[T, C] signatures = append_row(fixed_sigs, array_to_matrix(extra_sigs));

    // Scale exposures into activities
    if (family == 1) {
        // Multinomial model uses unscaled exposures
        activities = array_to_matrix(exposures);
    }
    else if (family == 2) {
        for (g in 1:G) {
            activities[g] = exposures[g]' * sum(counts_int[g]) * multiplier[g];
        }
    }
    else {
        for (g in 1:G) {
            activities[g] = exposures[g]' * sum(counts_real[g]) * multiplier[g];
        }
    }
    // Calculate expected counts (or probabilities)
    expected_counts = activities * signatures .* opportunities;

    if (family == 1) { // Multinomial requires a simplex
        for (g in 1:G) {
            expected_counts[g] = scale_row_to_sum_1(expected_counts[g]);
        }
    }
}

model {
    // Exposure priors (all models)
    for (g in 1:G) {
        exposures[g] ~ dirichlet(kappa);
    }

    for (n in 1:N) {
        // Priors for signatures
        extra_sigs[n] ~ dirichlet(alpha[n]');
    }

    // Multinomial ('NMF') model
    if (family == 1) {
        for (g in 1:G) {
            counts_int[g] ~ multinomial(expected_counts[g]');
        }
    }

    else {
        multiplier ~ cauchy(0, 2.5);

        // Poisson model family
        if (family == 2) {

            // Poisson ('EMu') model
            if (robust == 0) {
                for (g in 1:G) {
                    counts_int[g] ~ poisson(expected_counts[g]);
                }
            }

            // Negative binomial model
            else {
                //phi_raw ~ normal(0, 1);
                phi_raw ~ cauchy(0, 2.5);
                for (g in 1:G) {
                    // counts_int[g] ~ neg_binomial_2(expected_counts[g], phi);
                    counts_int[g] ~ neg_binomial_2(expected_counts[g], phi_raw);
                }
            }
        }

        // Normal model family
        else if (family == 3) {
            sigma ~ cauchy(0, 2.5);

            // Normal model
            if (robust == 0) {
                for (g in 1:G) {
                    counts_real[g] ~ normal(expected_counts[g], sigma[g]);
                }
            }

            // t model
            else {
                nu ~ gamma(2, 0.1);
                for (g in 1:G) {
                    counts_real[g] ~ student_t(nu, expected_counts[g], sigma[g]);
                }
            }
        }
    }
}
