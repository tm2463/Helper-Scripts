#!/usr/bin/env Rscript
# =============================================================================
# sylph_phylo_distances.R
#
# Credit goes to Claude
#
# Usage:
#   Rscript sylph_phylo_distances.R \
#     --sylph_dir path/to/profiles/  \
#     --tree      path/to/gtdb.tree  \
#     --out_dir   path/to/output/    \
#     [--min_cov 0]                  \
#     [--min_ani 0]                  \
#     [--format newick|nexus]
#
# Outputs written to <out_dir>/:
#   summary.tsv                          – One row per sample: sample, n_taxa, faiths_pd
#   <sample_name>/
#     <sample_name>_pruned.nwk           – Newick tree containing only identified taxa
#     <sample_name>_dist_matrix.tsv      – Pairwise phylogenetic distance matrix (N x N)
#     <sample_name>_dist_long.tsv        – Long-format distances
#     <sample_name>_tip_metadata.tsv     – Per-tip coverage / ANI metadata
#     <sample_name>_summary.txt          – Per-sample QC log
#
# Sample name:
#   Derived from the sylph TSV filename by stripping its extension.
#   e.g. results/sample_A.tsv  →  sample_A
#
# Accession matching:
#   Genome_file paths like:
#     gtdb_genomes_reps_r232/database/GCA/000/433/355/GCA_000433355.1_genomic.fna.gz
#   yield accession: GCA_000433355.1
#
#   GTDB tree tips are expected to look like:
#     GB_GCA_000433355.1   or   RS_GCF_000020605.1
#   The GB_/RS_ prefix is stripped for matching.
# =============================================================================

suppressPackageStartupMessages({
  library(ape)
  library(optparse)
  library(dplyr)
  library(tidyr)
  library(readr)
  library(stringr)
  library(purrr)
})

# ── 1. CLI argument parsing ───────────────────────────────────────────────────
option_list <- list(
  make_option(c("-s", "--sylph_dir"),
              type    = "character",
              help    = "Directory containing sylph profile TSV files [required]"),
  make_option(c("-t", "--tree"),
              type    = "character",
              help    = "Path to GTDB reference tree (Newick or Nexus) [required]"),
  make_option(c("-o", "--out_dir"),
              type    = "character",
              default = "sylph_phylo_out",
              help    = "Output directory [default: sylph_phylo_out]"),
  make_option(c("--min_cov"),
              type    = "double",
              default = 0.0,
              help    = "Minimum Eff_cov to retain a hit (default: 0, keep all)"),
  make_option(c("--min_ani"),
              type    = "double",
              default = 0.0,
              help    = "Minimum Adjusted_ANI to retain a hit (default: 0, keep all)"),
  make_option(c("--format"),
              type    = "character",
              default = "newick",
              help    = "Tree format: newick or nexus [default: newick]"),
  make_option(c("--verbose"),
              action  = "store_true",
              default = FALSE,
              help    = "Print extra diagnostic messages")
)

opt <- parse_args(OptionParser(option_list = option_list))

if (is.null(opt$sylph_dir) || is.null(opt$tree)) {
  stop("--sylph_dir and --tree are required. Run with --help for usage.")
}

if (!dir.exists(opt$sylph_dir)) {
  stop("--sylph_dir does not exist: ", opt$sylph_dir)
}

# Collect all TSV files in the input directory
sylph_files <- list.files(opt$sylph_dir,
                           pattern     = "\\.(tsv|txt|csv)$",
                           full.names  = TRUE,
                           recursive   = FALSE)

if (length(sylph_files) == 0) {
  stop("No .tsv / .txt / .csv files found in: ", opt$sylph_dir)
}

# Create top-level output directory
dir.create(opt$out_dir, showWarnings = FALSE, recursive = TRUE)

log_msg <- function(...) {
  cat(sprintf("[%s] %s\n", format(Sys.time(), "%H:%M:%S"), paste0(...)))
}
verbose_msg <- function(...) {
  if (isTRUE(opt$verbose)) log_msg(...)
}

# ── 2. Load GTDB tree (once, shared across all samples) ───────────────────────
log_msg("Reading GTDB tree: ", opt$tree)

read_fn   <- if (tolower(opt$format) == "nexus") read.nexus else read.tree
gtdb_tree <- tryCatch(read_fn(opt$tree),
                      error = function(e) stop("Cannot read tree: ", e$message))

if (inherits(gtdb_tree, "multiPhylo")) {
  log_msg("Multi-tree detected; using first tree.")
  gtdb_tree <- gtdb_tree[[1]]
}

log_msg(sprintf("Tree loaded: %d tips", Ntip(gtdb_tree)))

# Build accession-to-tip lookup once (reused for every sample)
tree_tips   <- gtdb_tree$tip.label
tip_bare    <- str_remove(tree_tips, "^[A-Z]{2}_")
bare_to_tip <- setNames(tree_tips, tip_bare)

match_to_tip <- function(acc) {
  if (acc %in% tree_tips)           return(acc)
  if (acc %in% names(bare_to_tip))  return(bare_to_tip[[acc]])
  acc_bare <- str_remove(acc, "^[A-Z]{2}_")
  if (acc_bare %in% names(bare_to_tip)) return(bare_to_tip[[acc_bare]])
  hits <- tree_tips[str_detect(tree_tips, fixed(acc_bare))]
  if (length(hits) == 1)  return(hits)
  if (length(hits)  > 1) {
    verbose_msg("Ambiguous match for '", acc, "' → using first: ", hits[1])
    return(hits[1])
  }
  return(NA_character_)
}

find_col <- function(df, candidates, role, required = TRUE) {
  found <- intersect(candidates, names(df))
  if (length(found) == 0) {
    if (required) stop(sprintf(
      "Cannot find '%s' column. Tried: %s\nActual columns: %s",
      role, paste(candidates, collapse = ", "), paste(names(df), collapse = ", ")))
    return(NA_character_)
  }
  found[1]
}

extract_accession <- function(path) {
  basename(path) %>%
    str_remove("_genomic\\.(fna|fa|fasta)(\\.gz)?$") %>%
    str_remove("\\.(fna|fa|fasta)(\\.gz)?$")
}

# ── 3. Per-sample processing function ─────────────────────────────────────────
process_sample <- function(sylph_path) {

  # Derive sample name from file name (strip extension)
  sample_name <- tools::file_path_sans_ext(basename(sylph_path))
  log_msg("=== Processing sample: ", sample_name, " ===")

  # Create per-sample subdirectory
  sample_dir <- file.path(opt$out_dir, sample_name)
  dir.create(sample_dir, showWarnings = FALSE, recursive = TRUE)
  out_prefix <- file.path(sample_dir, sample_name)

  # ── 3a. Load & filter sylph profile ────────────────────────────────────────
  sylph_raw <- tryCatch(
    read_tsv(sylph_path, show_col_types = FALSE),
    error = function(e) {
      log_msg("ERROR reading ", sylph_path, ": ", e$message)
      return(NULL)
    }
  )
  if (is.null(sylph_raw)) return(NULL)

  log_msg(sprintf("  Rows: %d  Columns: %d", nrow(sylph_raw), ncol(sylph_raw)))

  genome_col <- find_col(sylph_raw, c("Genome_file", "genome_file", "Genome"),    "Genome_file")
  cov_col    <- find_col(sylph_raw, c("Eff_cov", "Mean_cov_geq1", "Median_cov",
                                       "coverage", "Coverage"),                     "coverage")
  ani_col    <- find_col(sylph_raw, c("Adjusted_ANI", "Naive_ANI", "ANI", "ani"), "ANI")

  sylph_filt <- sylph_raw %>%
    filter(!is.na(.data[[genome_col]])) %>%
    filter(as.numeric(.data[[cov_col]])  >= opt$min_cov) %>%
    filter(as.numeric(.data[[ani_col]])  >= opt$min_ani) %>%
    mutate(accession = extract_accession(.data[[genome_col]]))

  log_msg(sprintf("  Retained %d / %d hits after filters",
                  nrow(sylph_filt), nrow(sylph_raw)))

  if (nrow(sylph_filt) == 0) {
    log_msg("  WARNING: No hits passed filters for ", sample_name, ". Skipping.")
    return(NULL)
  }

  # ── 3b. Match accessions to tree tips ──────────────────────────────────────
  unique_acc <- unique(sylph_filt$accession)
  acc_map    <- tibble(
    accession  = unique_acc,
    tree_label = map_chr(unique_acc, match_to_tip)
  )

  sylph_filt <- sylph_filt %>% left_join(acc_map, by = "accession")
  matched    <- sylph_filt %>% filter(!is.na(tree_label))
  unmatched  <- sylph_filt %>% filter( is.na(tree_label))

  log_msg(sprintf("  Matched %d / %d accessions to tree",
                  n_distinct(matched$accession),
                  n_distinct(sylph_filt$accession)))

  tips_to_keep <- unique(matched$tree_label)

  if (length(tips_to_keep) < 2) {
    log_msg("  WARNING: Fewer than 2 tips matched for ", sample_name, ". Skipping.")
    return(NULL)
  }

  # ── 3c. Prune tree ─────────────────────────────────────────────────────────
  tips_to_drop <- setdiff(tree_tips, tips_to_keep)
  pruned_tree  <- drop.tip(gtdb_tree, tips_to_drop)

  # ── 3d. Distances & Faith's PD ─────────────────────────────────────────────
  dist_matrix <- cophenetic.phylo(pruned_tree)
  dist_matrix <- dist_matrix[sort(rownames(dist_matrix)), sort(colnames(dist_matrix))]

  faith_pd <- sum(pruned_tree$edge.length, na.rm = TRUE)
  n_taxa   <- Ntip(pruned_tree)

  log_msg(sprintf("  Faith's PD = %.6f  |  n_taxa = %d", faith_pd, n_taxa))

  # ── 3e. Tip metadata ────────────────────────────────────────────────────────
  tip_meta <- matched %>%
    group_by(tree_label) %>%
    slice_max(order_by = as.numeric(.data[[cov_col]]), n = 1, with_ties = FALSE) %>%
    ungroup() %>%
    select(tree_label, accession,
           genome_file  = all_of(genome_col),
           eff_cov      = all_of(cov_col),
           adjusted_ani = all_of(ani_col),
           any_of(c("Taxonomic_abundance", "Sequence_abundance",
                     "Taxonomic_label",   "Contig_name")))

  # ── 3f. Long-format distance table ─────────────────────────────────────────
  dist_long <- as.data.frame(as.table(dist_matrix)) %>%
    rename(taxon_A = Var1, taxon_B = Var2, phylo_distance = Freq) %>%
    filter(as.character(taxon_A) < as.character(taxon_B)) %>%
    arrange(phylo_distance)

  meta_a <- tip_meta %>% select(tree_label, accession_A = accession,
                                 eff_cov_A = eff_cov, adj_ani_A = adjusted_ani)
  meta_b <- tip_meta %>% select(tree_label, accession_B = accession,
                                 eff_cov_B = eff_cov, adj_ani_B = adjusted_ani)

  dist_long <- dist_long %>%
    left_join(meta_a, by = c("taxon_A" = "tree_label")) %>%
    left_join(meta_b, by = c("taxon_B" = "tree_label"))

  # ── 3g. Write per-sample outputs ────────────────────────────────────────────
  write.tree(pruned_tree,
             file = paste0(out_prefix, "_pruned.nwk"))

  dist_df <- as.data.frame(dist_matrix)
  dist_df <- cbind(taxon = rownames(dist_df), dist_df)
  write_tsv(dist_df,  paste0(out_prefix, "_dist_matrix.tsv"))

  write_tsv(dist_long, paste0(out_prefix, "_dist_long.tsv"))
  write_tsv(tip_meta,  paste0(out_prefix, "_tip_metadata.tsv"))

  # ── 3h. Per-sample QC log ──────────────────────────────────────────────────
  out_summary <- paste0(out_prefix, "_summary.txt")
  sink(out_summary)
  cat("=== sylph_phylo_distances.R — Sample Summary ===\n\n")
  cat(sprintf("Sample          : %s\n", sample_name))
  cat(sprintf("Date/time       : %s\n", Sys.time()))
  cat(sprintf("Sylph profile   : %s\n", sylph_path))
  cat(sprintf("GTDB tree       : %s\n", opt$tree))
  cat(sprintf("Min Eff_cov     : %.3f\n", opt$min_cov))
  cat(sprintf("Min ANI         : %.3f\n", opt$min_ani))
  cat("\n--- Filtering ---\n")
  cat(sprintf("Total sylph rows         : %d\n", nrow(sylph_raw)))
  cat(sprintf("After cov/ANI filter     : %d\n", nrow(sylph_filt)))
  cat(sprintf("Unique accessions        : %d\n", n_distinct(sylph_filt$accession)))
  cat(sprintf("Matched to tree          : %d\n", n_distinct(matched$accession)))
  cat(sprintf("Unmatched (dropped)      : %d\n", n_distinct(unmatched$accession)))
  if (nrow(unmatched) > 0) {
    cat("\nUnmatched accessions:\n")
    walk(unique(unmatched$accession), ~ cat(sprintf("  %s\n", .x)))
  }
  cat("\n--- Tree ---\n")
  cat(sprintf("Original tips            : %d\n", Ntip(gtdb_tree)))
  cat(sprintf("Pruned tips              : %d\n", n_taxa))
  cat("\n--- Distance Summary ---\n")
  cat(sprintf("Pairwise comparisons     : %d\n", nrow(dist_long)))
  cat(sprintf("Min distance             : %.6f\n", min(dist_long$phylo_distance)))
  cat(sprintf("Max distance             : %.6f\n", max(dist_long$phylo_distance)))
  cat(sprintf("Mean distance            : %.6f\n", mean(dist_long$phylo_distance)))
  cat(sprintf("Median distance          : %.6f\n", median(dist_long$phylo_distance)))
  cat(sprintf("Faith's PD               : %.6f\n", faith_pd))
  cat("\n--- Matched taxa (tree label  |  accession  |  Eff_cov  |  ANI) ---\n")
  tip_meta %>%
    arrange(desc(as.numeric(eff_cov))) %>%
    mutate(line = sprintf("  %-35s  %-25s  cov=%-8.3f  ANI=%.2f",
                          tree_label, accession,
                          as.numeric(eff_cov), as.numeric(adjusted_ani))) %>%
    pull(line) %>%
    walk(cat, "\n")
  cat("\n--- 10 closest pairs ---\n")
  print(head(dist_long %>% select(taxon_A, taxon_B, phylo_distance,
                                  accession_A, accession_B), 10),
        row.names = FALSE)
  sink()

  log_msg("  Outputs written to: ", sample_dir)

  # Return the row for the top-level summary
  tibble(
    sample   = sample_name,
    n_taxa   = n_taxa,
    faiths_pd = faith_pd
  )
}

# ── 4. Run across all samples ─────────────────────────────────────────────────
log_msg(sprintf("Found %d sylph profile(s) in: %s", length(sylph_files), opt$sylph_dir))

summary_rows <- map(sylph_files, process_sample)

# ── 5. Write top-level summary TSV ───────────────────────────────────────────
summary_tbl <- bind_rows(Filter(Negate(is.null), summary_rows))

out_summary_tsv <- file.path(opt$out_dir, "summary.tsv")
write_tsv(summary_tbl, out_summary_tsv)

log_msg(sprintf("Top-level summary (%d samples) → %s", nrow(summary_tbl), out_summary_tsv))
log_msg("Done.")
