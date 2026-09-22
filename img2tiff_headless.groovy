import qupath.lib.images.ImageData
import qupath.lib.images.servers.ImageServerBuilder
import qupath.lib.projects.Project
import qupath.lib.projects.ProjectIO
import qupath.lib.images.writers.ome.OMETiffWriter
import qupath.lib.images.writers.ome.OMEPyramidWriter

// Convert image to OME-TIFF pyramid

String makeOutputPrefix(
    String outputFolder,
    String inputPath,
    String file_ext,
    String series,
    String name
) {
    if (!inputPath.endsWith(".${file_ext}")) {
        println "Input must be a image with .${file_ext} suffix (received ${inputPath})"
        throw new IllegalArgumentException("Input must be a image with .${file_ext} suffix (received ${inputPath})")
    }
    def suffix = !name.endsWith(".${file_ext}") || name.contains(" - ") ? name.split(" - ")[1].replace(" ", "_") : series
    def outputName = inputPath.replaceFirst(/.*\//, '').replaceFirst(/\.${file_ext}$/, '.' + suffix)
    return outputFolder.endsWith(File.separator) ? outputFolder + outputName : outputFolder + File.separator + outputName
}

def writeOmeTiff(ImageServer server, String outputPath) {
    // single JPEG plane not currently used
    try {
        def writer = new OMETiffWriter()
        println "Writing OME-TIFF to: ${outputPath}"
        writer.writeImage(server, outputPath)
        println "Write complete: ${outputPath}"
    } catch (Exception e) {
        println "Error writing OME-TIFF: ${e.message}"
    }
}

def writeOmePyramid(ImageServer server, String outputPath, OMEPyramidWriter.CompressionType compression) {

    def tileSize = 1024
    def nThreads = 2

    try {
        def writer = new OMEPyramidWriter.Builder(server)
            .tileSize(tileSize)
            .channelsInterleaved()
            .compression(compression)
	    .dyadicDownsampling()
            .parallelize(nThreads)
            .build()
        writer.writePyramid(outputPath)
        println "OME Pyramid TIFF written to: ${outputPath}"
    } catch (Exception e) {
        // Must not be swallowed: the caller stops iterating series on
        // IllegalArgumentException, so a write failure reported only on stdout would
        // leave the series missing and the conversion looking successful.
        println "Error writing OME Pyramid TIFF: ${e.message}"
        throw new RuntimeException("Failed to write ${outputPath}", e)
    }
}

def checkFileExistence(String outputFilename) {
    def outputFile = new File(outputFilename)
    if (outputFile.exists()) {
        throw new IllegalArgumentException("File already exists: ${outputFile.absolutePath}")
    }
}

def buildImageServer(String inputFilename, String series) {
    try {
        return buildServer(inputFilename, "--series", series)
    } catch (Exception e) {
        throw new IllegalArgumentException("Error building image server: ${e.message}")
    }
}

def convert(String[] args) {

    // Default to lossy (Could be ZLIB LZW UNCOMPRESSED JPEG (not working with 32bit: J2K_LOSSY J2K)
    def compression = OMEPyramidWriter.CompressionType.JPEG

    println "Input Arguments: ${args}"

    if (args.size() < 1) {
        throw new IllegalArgumentException("Input filename is required")
    }
    String inputFilename = args[0]

    if (args.size() < 2) {
        throw new IllegalArgumentException("Output folder name is required")
    }
    String outputFolder = args[1]

    if (args.size() >= 3) {
        // Accept anything OMEPyramidWriter does, so this path offers the same
        // choices as the convert-ome CLI rather than a subset of them.
        try {
            compression = OMEPyramidWriter.CompressionType.valueOf(args[2])
        } catch (IllegalArgumentException e) {
            throw new IllegalArgumentException(
                "Unknown compression '${args[2]}'. Valid values: " +
                OMEPyramidWriter.CompressionType.values().join(", ")
            )
        }
    }

    // The user may optionally specify the file extension (e.g. vsi, svs, scn)
    if (args.size() >= 4) {
        file_ext = args[3]
    } else {
        file_ext = "vsi"
    }

    println "Input Filename: ${inputFilename}"
    println "File extension: ${file_ext}"
    println "Output Folder: ${outputFolder}"

    Boolean keep_going = true

    for (int s = 0; keep_going; s++) {
        String series = s
        try {
            convertSeries(outputFolder, inputFilename, file_ext, series, compression)
        } catch (IllegalArgumentException e) {
            println "Stopping iteration"
            keep_going = false
        }
        // Do not create more than 10 series per image
        if (s == 10) {
            keep_going = false
        }
    }
}

def saveMetadata(ImageServer server, String outputPrefix) {
    def metadata = server.getMetadata()
    def jsonFilename = outputPrefix + ".metadata.json"
    def file = new File(jsonFilename)
    file.withWriter { writer ->
        writer.println(metadata)
    }
    println "Metadata saved to: ${jsonFilename}"
}

def convertSeries(
    String outputFolder,
    String inputFilename,
    String file_ext,
    String series,
    OMEPyramidWriter.CompressionType compression
) {

    println "Converting series ${series}"

    def server = buildImageServer(inputFilename, series)

    name = server.getMetadata()["name"]
    println "Series name: ${name}"
    String outputPrefix = makeOutputPrefix(outputFolder, inputFilename, file_ext, series, name)
    println "Output prefix: ${outputPrefix}"

    // Save the series metadata to JSON
    saveMetadata(server, outputPrefix)

    def outputFilename = outputPrefix + ".ome.tif"

    println "Writing to ${outputFilename}"

    // Include the series number in the output file name
    checkFileExistence(outputFilename)
    println "Output Filename: ${outputFilename}"

    // Write image as OME TIFF Pyramid
    writeOmePyramid(server, outputFilename, compression)
}

// Run the main function, renamed to avoid collision
convert(args)
