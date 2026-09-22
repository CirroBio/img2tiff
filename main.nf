#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

// Formats which pack several independent images into a single file. QuPath's
// convert-ome CLI reads one series, so these go through the Groovy script, which
// walks every series in turn. Everything else uses the CLI directly.
MULTI_SERIES_FORMATS = ['vsi', 'scn', 'dcm', 'dicom', 'nd2', 'lif', 'czi']

// QuPath appends .ome.tif itself when the output path lacks it, deriving the stem with
// getNameWithoutExtension -- which truncates at the last dot, so "a.b.svs" would be
// written as "a.ome.tif". Passing the full name keeps the stem intact.
def outputName(String imageName) {
    def suffix = ".${params.image_format}"
    def stem = imageName.toLowerCase().endsWith(suffix.toLowerCase())
        ? imageName[0..<(imageName.length() - suffix.length())]
        : imageName
    return stem
}

def findImages() {
    def input_folder = file(params.input_folder, type: 'dir', checkIfExists: true)

    // '**' crosses directory boundaries, so slides nested under the input folder are
    // matched as well as slides sitting directly in it.
    def images = files("${input_folder}/**.${params.image_format}")

    if (images.isEmpty()) {
        def present = input_folder.list().sort()
        error """
            |No *.${params.image_format} files found under ${input_folder}
            |
            |Its top level holds ${present.size()} entries: ${present.take(25).join(', ')}
            |Set --image_format to the suffix the images actually carry.
            |""".stripMargin()
    }

    def duplicates = images.groupBy { it.name }.findAll { name, paths -> paths.size() > 1 }
    if (duplicates) {
        error """
            |${duplicates.size()} image name(s) occur more than once under ${input_folder}.
            |Outputs are named after the image, so these would overwrite each other:
            |${duplicates.keySet().take(10).collect { "  ${it}" }.join('\n')}
            |""".stripMargin()
    }

    if (params.skip_existing) {
        // One listing of the output folder rather than a stat per image, which matters
        // when the output is object storage and the cohort runs to hundreds of slides.
        def output_folder = file(params.output)
        def converted = output_folder.exists()
            ? output_folder.list().findAll { it.endsWith('.ome.tif') }.collect { it - ~/\.ome\.tif$/ } as Set
            : [] as Set
        // A multi-series image writes <stem>.<series>.ome.tif, so match the stem too.
        def pending = images.findAll { image ->
            def stem = outputName(image.name)
            !converted.any { it == stem || it.startsWith("${stem}.") }
        }
        log.info "skip_existing: ${images.size() - pending.size()} of ${images.size()} already converted"
        images = pending
    }

    log.info "Converting ${images.size()} ${params.image_format} image(s) from ${input_folder}"
    return images
}


process convert_image_series {
    tag "${image.name}"
    container "${params.container}"
    publishDir params.output, overwrite: true, mode: "copy",
               saveAs: { name -> name.endsWith(".timing.tsv") ? null : name }

    input:
        path image
        path script

    output:
        path "*.ome.tif",       emit: converted
        path "*.log.txt",       emit: log
        path "*.metadata.json", emit: metadata
        path "*.timing.tsv",    emit: timing

    script:
        def stem = outputName(image.name)
        """#!/bin/bash
set -euo pipefail

START=\$(date +%s)
echo "\$(date -u +%FT%TZ) Converting ${image.name}"

# QuPath returns 0 even when it cannot read an image -- it logs the exception and
# carries on -- so success is asserted on the output below, never on the exit status.
QuPath script \\
    --args "${image}" \\
    --args "\$PWD" \\
    --args "${params.compression}" \\
    --args "${params.image_format}" \\
    "${script}" 2>&1 | tee "${stem}.log.txt"

shopt -s nullglob
WRITTEN=( *.ome.tif )
if [ \${#WRITTEN[@]} -eq 0 ]; then
    echo "FAILED: QuPath wrote no series from ${image.name}; see ${stem}.log.txt" >&2
    exit 1
fi
if grep -q "Error writing OME Pyramid TIFF" "${stem}.log.txt"; then
    echo "FAILED: a series of ${image.name} could not be written; see ${stem}.log.txt" >&2
    exit 1
fi

ELAPSED=\$(( \$(date +%s) - START ))
printf 'image\\tseconds\\tinput_bytes\\toutput_bytes\\toutput_files\\n' > "${stem}.timing.tsv"
printf '%s\\t%s\\t%s\\t%s\\t%s\\n' \\
    "${image.name}" "\$ELAPSED" \\
    "\$(stat -Lc %s "${image}")" \\
    "\$(du -Lcb *.ome.tif | tail -1 | cut -f1)" \\
    "\$(ls -1 *.ome.tif | wc -l)" >> "${stem}.timing.tsv"
echo "\$(date -u +%FT%TZ) Done in \${ELAPSED}s"
        """
}


process convert_image {
    tag "${image.name}"
    container "${params.container}"
    publishDir params.output, overwrite: true, mode: "copy",
               saveAs: { name -> name.endsWith(".timing.tsv") ? null : name }

    input:
        path image

    output:
        path "*.ome.tif",    emit: converted
        path "*.log.txt",    emit: log
        path "*.timing.tsv", emit: timing

    script:
        def stem = outputName(image.name)
        """#!/bin/bash
set -euo pipefail

START=\$(date +%s)
echo "\$(date -u +%FT%TZ) Converting ${image.name} -> ${stem}.ome.tif"

# QuPath returns 0 even when it cannot read an image -- it logs the exception and
# carries on -- so success is asserted on the output below, never on the exit status.
QuPath convert-ome \\
    "${image}" \\
    "${stem}.ome.tif" \\
    --pyramid-scale=${params.pyramid_scale} \\
    --tile-size=${params.tile_size} \\
    --compression=${params.compression} \\
    --parallelize 2>&1 | tee "${stem}.log.txt"

if [ ! -s "${stem}.ome.tif" ]; then
    echo "FAILED: no output written for ${image.name}; see ${stem}.log.txt" >&2
    exit 1
fi

ELAPSED=\$(( \$(date +%s) - START ))
printf 'image\\tseconds\\tinput_bytes\\toutput_bytes\\n' > "${stem}.timing.tsv"
printf '%s\\t%s\\t%s\\t%s\\n' \\
    "${image.name}" "\$ELAPSED" \\
    "\$(stat -Lc %s "${image}")" \\
    "\$(stat -Lc %s "${stem}.ome.tif")" >> "${stem}.timing.tsv"
echo "\$(date -u +%FT%TZ) Done in \${ELAPSED}s"
        """
}


workflow {
    images = Channel.fromList(findImages())

    if ( params.image_format in MULTI_SERIES_FORMATS ) {
        script = file("$projectDir/img2tiff_headless.groovy", checkIfExists: true)
        convert_image_series(images, script)
        timing = convert_image_series.out.timing
    } else {
        convert_image(images)
        timing = convert_image.out.timing
    }

    timing.collectFile(
        name: "conversion_timings.tsv",
        storeDir: params.output,
        keepHeader: true,
        skip: 1,
        sort: true
    )
}
