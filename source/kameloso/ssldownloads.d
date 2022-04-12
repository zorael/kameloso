/++
    Bits and bobs that download SSL libraries and related necessities on Windows.
 +/
module kameloso.ssldownloads;

version(Windows):

private:

import kameloso.kameloso : Kameloso;
import std.typecons : Flag, No, Yes;

public:


// downloadWindowsSSL
/++
    Downloads OpenSSL for Windows and/or a `cacert.pem` certificate bundle from
    the cURL project, extracted from Mozilla Firefox.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
        shouldDownloadCacert = Whether or not `cacert.pem` should be downloaded.
        shouldDownloadOpenSSL = Whether or not OpenSSL for Windows should be downloaded.
 +/
bool downloadWindowsSSL(
    ref Kameloso instance,
    const Flag!"shouldDownloadCacert" shouldDownloadCacert,
    const Flag!"shouldDownloadOpenSSL" shouldDownloadOpenSSL)
{
    import kameloso.common : expandTags, logger;
    import kameloso.logger : LogLevel;
    import std.file : mkdirRecurse, tempDir;
    import std.path : buildNormalizedPath;

    static int downloadFile(const string url, const string saveAs)
    {
        import std.format : format;
        import std.process : executeShell;

        enum pattern = "Downloading <l>%s</>...";
        logger.infof(pattern.expandTags(LogLevel.info), url);

        enum executePattern = `powershell -c "Invoke-WebRequest '%s' -OutFile '%s'"`;
        immutable result = executeShell(executePattern.format(url, saveAs));

        if (result.status != 0)
        {
            import std.stdio : stdout, writeln;
            import std.string : chomp;

            enum errorPattern = "Download process failed with status <l>%d</>!";
            logger.errorf(errorPattern.expandTags(LogLevel.error), result.status);

            version(PrintStacktraces)
            {
                writeln(result.output.chomp);
                stdout.flush();
            }
        }

        return result.status;
    }

    bool retval;

    if (shouldDownloadCacert)
    {
        import std.path : dirName;

        enum cacertURL = "http://curl.se/ca/cacert.pem";
        immutable configDir = instance.settings.configFile.dirName;
        immutable cacertFile = buildNormalizedPath(configDir, "cacert.pem");
        immutable result = downloadFile(cacertURL, cacertFile);

        if (result == 0)
        {
            if (!instance.settings.force)
            {
                enum cacertPattern = "File saved as <l>%s</>; configuration updated.";
                logger.infof(cacertPattern.expandTags(LogLevel.info), cacertFile);
                instance.connSettings.caBundleFile = "cacert.pem";  // cacertFile
            }
            retval = true;
        }
    }

    if (shouldDownloadOpenSSL)
    {
        import lu.string : beginsWith;
        import std.algorithm.searching : endsWith;
        import std.file : readText;
        import std.json : JSONException, parseJSON;
        import std.process : ProcessException;

        immutable temporaryDir = buildNormalizedPath(tempDir, "kameloso");
        mkdirRecurse(temporaryDir);

        enum jsonURL = "https://raw.githubusercontent.com/slproweb/opensslhashes/master/win32_openssl_hashes.json";
        immutable jsonFile = buildNormalizedPath(temporaryDir, "win32_openssl_hashes.json");
        immutable result = downloadFile(jsonURL, jsonFile);
        if (result != 0) return retval;

        try
        {
            const hashesJSON = parseJSON(readText(jsonFile));
            bool found;

            foreach (immutable filename, fileEntryJSON; hashesJSON["files"].object)
            {
                version(Win64)
                {
                    enum head = "Win64OpenSSL_Light-1_";
                }
                else /*version(Win32)*/
                {
                    enum head = "Win32OpenSSL_Light-1_";
                }

                if (filename.beginsWith(head) && filename.endsWith(".exe"))
                {
                    import std.process : execute;

                    found = true;

                    immutable exeFile = buildNormalizedPath(temporaryDir, filename);
                    immutable downloadResult = downloadFile(fileEntryJSON["url"].str, exeFile);
                    if (downloadResult != 0) break;

                    logger.info("Launching OpenSSL installer.");
                    cast(void)execute([ exeFile ]);
                    break;
                }
            }

            if (!found)
            {
                logger.error("Could not find OpenSSL .exe to download");
            }
        }
        catch (JSONException e)
        {
            enum pattern = "Error parsing file containing OpenSSL download links: <l>%s";
            logger.errorf(pattern.expandTags(LogLevel.error), e.msg);
        }
        catch (ProcessException e)
        {
            enum pattern = "Error starting installer: <l>%s";
            logger.errorf(pattern.expandTags(LogLevel.error), e.msg);
        }
    }

    return retval;
}
