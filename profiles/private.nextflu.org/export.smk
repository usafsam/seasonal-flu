FREQUENCY_REGIONS = [
    'Africa',
    'Europe',
    'North America',
    'China',
    'South Asia',
    'Japan Korea',
    'Oceania',
    'South America',
    'Southeast Asia',
    'West Asia',
]

rule all_who:
    input:
        [
            "auspice-who/" + build.get("auspice_name", f"{build_name}_{{segment}}").format(segment=segment) + "_" + suffix + ".json"
            for build_name, build in config["builds"].items()
            for segment in config["segments"]
            for suffix in ['tree', 'meta', 'frequencies', 'titers', 'titer-tree-model', 'titer-sub-model', 'entropy', 'sequences']
        ],

def _get_file_by_auspice_name(wildcards):
    for build_name, build_params in config["builds"].items():
        for segment in config["segments"]:
            if build_params.get("auspice_name", f"{build_name}_{{segment}}").format(segment=segment) == wildcards.auspice_name:
                return f"auspice/{build_name}_{segment}_{wildcards.suffix}.json"

    return ""

rule rename_auspice_file:
    input:
        _get_file_by_auspice_name,
    output:
        "auspice-who/{auspice_name}_{suffix}.json",
    shell:
        """
        ln {input} {output}
        """

rule tree_frequencies:
    input:
        tree = rules.refine.output.tree,
        metadata = build_dir + "/{build_name}/metadata.tsv"
    params:
        min_date = lambda wildcards: config["builds"][wildcards.build_name].get("min_date"),
        pivot_interval = 1,
        regions = ['global'] + FREQUENCY_REGIONS,
        min_clade = 20,
    output:
        frequencies = build_dir + "/{build_name}/{segment}/tree_frequencies.json",
    conda: "../../workflow/envs/nextstrain.yaml"
    shell:
        """
        augur frequencies \
            --method diffusion \
            --include-internal-nodes \
            --tree {input.tree} \
            --regions {params.regions:q} \
            --metadata {input.metadata} \
            --pivot-interval {params.pivot_interval} \
            --minimal-clade-size {params.min_clade} \
            --min-date {params.min_date} \
            --output {output}
        """

checkpoint filter_translations_by_region:
    input:
        translations=build_dir + "/{build_name}/{segment}/translations.done",
        metadata = build_dir + "/{build_name}/metadata.tsv",
        exclude = lambda wildcards: config["builds"][wildcards.build_name]["exclude"],
    output:
        translations = build_dir + "/{build_name}/{segment}/translations_by_region/{region}/{gene}.fasta",
    params:
        translations = build_dir + "/{build_name}/{segment}/translations/{gene}.fasta",
        min_date = lambda wildcards: config["builds"][wildcards.build_name].get("min_date"),
    conda: "../../workflow/envs/nextstrain.yaml"
    shell:
        """
        augur filter \
            --sequences {params.translations} \
            --metadata {input.metadata} \
            --exclude {input.exclude} \
            --query "region == '{wildcards.region}'" \
            --min-date {params.min_date} \
            --empty-output-reporting warn \
            --output-sequences {output.translations:q}
        """

def region_translations(wildcards):
    return [
        f"{build_dir}/{wildcards.build_name}/{wildcards.segment}/translations_by_region/{wildcards.region}/{gene}.fasta"
        for gene in GENES[wildcards.segment]
    ]

rule complete_mutation_frequencies_by_region:
    input:
        metadata = build_dir + "/{build_name}/metadata.tsv",
        alignment = region_translations,
    params:
        genes = lambda w: GENES[w.segment],
        min_date = lambda wildcards: config["builds"][wildcards.build_name].get("min_date"),
        max_date = "0D",
        min_freq = 0.003,
        pivot_interval = 1,
        stiffness = 20,
        inertia = 0.2,
    output:
        mut_freq = build_dir + "/{build_name}/{segment}/mutation_frequencies/{region}.json"
    conda: "../../workflow/envs/nextstrain.yaml"
    benchmark:
        "benchmarks/mutation_frequencies_{build_name}_{segment}_{region}.txt"
    log:
        "logs/mutation_frequencies_{build_name}_{segment}_{region}.txt"
    resources:
        mem_mb=4000,
    shell:
        """
        augur frequencies \
            --method diffusion \
            --alignments {input.alignment:q} \
            --metadata {input.metadata} \
            --gene-names {params.genes:q} \
            --pivot-interval {params.pivot_interval} \
            --stiffness {params.stiffness} \
            --inertia {params.inertia} \
            --ignore-char X \
            --min-date {params.min_date} \
            --max-date {params.max_date} \
            --minimal-frequency {params.min_freq} \
            --output {output.mut_freq:q} &> {log:q}
        """

def _get_region_mutation_frequencies(wildcards):
    """Find all non-empty gene translations per region and return the
    corresponding list of regional mutation frequencies JSON that should be
    estimated from the remaining translations. This logic avoids trying to
    estimate frequencies for regions with empty alignments.
    """
    region_mutation_frequencies = []
    for region in FREQUENCY_REGIONS:
        any_empty_translations = False
        for gene in GENES[wildcards.segment]:
            checkpoint_wildcards = {
                "build_name": wildcards.build_name,
                "segment": wildcards.segment,
                "region": region,
                "gene": gene,
            }
            with checkpoints.filter_translations_by_region.get(**checkpoint_wildcards).output[0].open() as fh:
                any_empty_translations |= len(fh.read(1).strip()) == 0
                if any_empty_translations:
                    break

        if not any_empty_translations:
            region_mutation_frequencies.append(f"{build_dir}/{wildcards.build_name}/{wildcards.segment}/mutation_frequencies/{region}.json")

    return region_mutation_frequencies

rule global_mutation_frequencies:
    input:
        frequencies = _get_region_mutation_frequencies,
        tree_freq = rules.tree_frequencies.output,
    params:
        regions = FREQUENCY_REGIONS
    output:
        auspice="auspice/{build_name}_{segment}_frequencies.json",
    conda: "../../workflow/envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/global_frequencies.py --region-frequencies {input.frequencies:q} \
                                              --tree-frequencies {input.tree_freq} \
                                              --regions {params.regions:q} \
                                              --output-auspice {output.auspice}
        """

rule scores:
    input:
        metadata = build_dir + "/{build_name}/metadata.tsv",
        tree = build_dir + "/{build_name}/{segment}/tree.nwk",
    output:
        node_data = build_dir + "/{build_name}/{segment}/scores.json",
    conda: "../../workflow/envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/scores.py  --metadata {input.metadata} \
                                  --tree {input.tree} \
                                  --output {output}
        """

rule export_titers:
    input:
        sub = "builds/{build_name}/{segment}/titers-sub-model/titers.json",
        tree = "builds/{build_name}/{segment}/titers-tree-model/titers.json",
    output:
        raw = "auspice/{build_name}_{segment}_titers.json",
        tree = "auspice/{build_name}_{segment}_titer-tree-model.json",
        sub = "auspice/{build_name}_{segment}_titer-sub-model.json",
    conda: "../../workflow/envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/export_titers_for_auspice_v1.py \
            --titers-sub {input.sub} \
            --titers-tree {input.tree} \
            --output-titers {output.raw} \
            --output-titers-sub {output.sub} \
            --output-titers-tree {output.tree}
        """

rule export_entropy:
    input:
        aln = rules.align.output.alignment,
        gene_map = lambda w: config['builds'][w.build_name]['annotation'],
    params:
        genes = lambda w: GENES[w.segment],
    output:
        "auspice/{build_name}_{segment}_entropy.json",
    conda: "../../workflow/envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/entropy.py --alignment {input.aln} \
                --genes {params.genes} \
                --gene-map {input.gene_map} \
                --output {output}
        """

rule export_sequence_json:
    input:
        aln = rules.ancestral.output.node_data,
        tree = rules.refine.output.tree,
        translations_done = build_dir + "/{build_name}/{segment}/translations.done"
    params:
        translations = lambda w: [f"{build_dir}/{w.build_name}/{w.segment}/translations/{gene}_withInternalNodes.fasta" for gene in GENES[w.segment]],
        genes = lambda w: GENES[w.segment]
    output:
        "auspice/{build_name}_{segment}_sequences.json",
    conda: "../../workflow/envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/sequence_export.py --alignment {input.aln} \
                --genes {params.genes} \
                --tree {input.tree} \
                --translations {params.translations} \
                --output {output}
        """

def _get_node_data_for_report_export(wildcards):
    """Return a list of node data files to include for a given build's wildcards.
    """
    # Define inputs shared by all builds.
    inputs = [
        rules.annotate_epiweeks.output.node_data,
        rules.annotate_recency_of_submissions.output.node_data,
        rules.refine.output.node_data,
        rules.ancestral.output.node_data,
        rules.clades.output.node_data,
        rules.traits.output.node_data,
        rules.scores.output.node_data,
    ]

    # Only request a distance file for builds that have mask configurations
    # defined.
    if _get_build_distance_map_config(wildcards) is not None:
        inputs.append(rules.distances.output.distances)

    if config["builds"][wildcards.build_name].get('enable_titer_models', False) and wildcards.segment == 'ha':
        for collection in config["builds"][wildcards.build_name]["titer_collections"]:
            inputs.append(rules.titers_sub.output.titers_model.format(titer_collection=collection["name"], **wildcards))
            inputs.append(rules.titers_tree.output.titers_model.format(titer_collection=collection["name"], **wildcards))

    if config["builds"][wildcards.build_name].get('enable_glycosylation', False) and wildcards.segment in ['ha', 'na']:
        inputs.append(rules.glyc.output.glyc)

    if config["builds"][wildcards.build_name].get('enable_lbi', False) and wildcards.segment in ['ha', 'na']:
        inputs.append(rules.lbi.output.lbi)

    # Convert input files from wildcard strings to real file names.
    inputs = [input_file.format(**wildcards) for input_file in inputs]
    return inputs

rule export_who:
    input:
        tree = build_dir + "/{build_name}/{segment}/tree.nwk",
        metadata = build_dir + "/{build_name}/metadata.tsv",
        auspice_config = lambda w: config['builds'][w.build_name]['auspice_config'],
        node_data = _get_node_data_for_report_export,
        colors = "config/colors.tsv",
    output:
        tree = "auspice/{build_name}_{segment}_tree.json",
        meta = "auspice/{build_name}_{segment}_meta.json",
    conda: "../../workflow/envs/nextstrain.yaml"
    shell:
        """
        augur export v1 \
            --tree {input.tree} \
            --metadata {input.metadata} \
            --node-data {input.node_data} \
            --auspice-config {input.auspice_config} \
            --colors {input.colors} \
            --output-tree {output.tree} \
            --output-meta {output.meta} \
            --minify-json
        """
