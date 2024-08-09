/++
    Bits and bobs that automate downloading SSL libraries and related necessities on Windows.

    TODO: Replace with Windows Secure Channel SSL.

    See_Also:
        [kameloso.net]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.ssldownloads;

version(Windows):

private:

import kameloso.kameloso : Kameloso;

public:


// downloadWindowsSSL
/++
    Downloads OpenSSL for Windows and/or a `cacert.pem` certificate bundle from
    the cURL project, extracted from Mozilla Firefox.

    If `--force` was not supplied, the configuration file is updated with "`cacert.pem`"
    entered as `caBundle`. If it is supplied, the value is still changed but to the
    absolute path to the file, and the configuration file is not implicitly updated.
    (`--save` will have to be separately passed.)

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
        shouldDownloadCacert = Whether or not `cacert.pem` should be downloaded.
        shouldDownloadOpenSSL = Whether or not OpenSSL for Windows should be downloaded.
        shouldDownloadOpenSSL1_1 = Whether or not OpenSSL v1.1 should be downloaded
            instead of v3.2.

    Returns:
        `true` if [kameloso.kameloso.Kameloso.settings|Kameloso.settings]
        were touched and the configuration file should be updated; `false` if not.
 +/
auto downloadWindowsSSL(
    Kameloso instance,
    const bool shouldDownloadCacert,
    const bool shouldDownloadOpenSSL,
    const bool shouldDownloadOpenSSL1_1)
{
    import kameloso.common : logger;
    import std.path : buildNormalizedPath;

    static int downloadFile(
        const string url,
        const string what,
        const string saveAs)
    {
        import std.process : execute;

        enum pattern = "Downloading %s from <l>%s</>...";
        logger.infof(pattern, what, url);

        immutable string[3] command =
        [
            "powershell.exe",
            "-c",
            "Invoke-WebRequest '" ~ url ~ "' -OutFile '" ~ saveAs ~ "'",
        ];
        immutable result = execute(command[]);

        if (result.status != 0)
        {
            enum errorPattern = "Download process failed with status <l>%d</>!";
            logger.errorf(errorPattern, result.status);

            version(PrintStacktraces)
            {
                import std.stdio : stdout, writeln;
                import std.string : chomp;

                immutable output = result.output.chomp;

                if (output.length)
                {
                    writeln(output);
                    stdout.flush();
                }
            }
        }

        return result.status;
    }

    void resolveCacert()
    {
        if (instance.connSettings.caBundleFile.length)
        {
            import std.file : exists, isDir, isFile;

            if (!instance.connSettings.caBundleFile.exists)
            {
                // Filename specified and nothing is in the way, use it
            }
            else if (instance.connSettings.caBundleFile.isDir)
            {
                // Place the file inside the given directory
                instance.connSettings.caBundleFile = buildNormalizedPath(
                    instance.connSettings.caBundleFile,
                    "cacert.pem");
            }
            else
            {
                // Assume a proper file is already in place
            }
        }
        else
        {
            import std.path : dirName;

            // Save next to the configuration file
            // Can't use instance.settings.configDirectory; it hasn't been resolved yet
            instance.connSettings.caBundleFile = buildNormalizedPath(
                instance.settings.configFile.dirName,
                "cacert.pem");
        }
    }

    auto downloadCacert()
    {
        import kameloso.string : doublyBackslashed;

        enum cacertURL = "https://curl.se/ca/cacert.pem";
        immutable result = downloadFile(
            cacertURL,
            "certificate bundle",
            instance.connSettings.caBundleFile);
        if (*instance.abort) return false;

        if (result == 0)
        {
            if (!instance.settings.force)
            {
                enum cacertPattern = "File saved as <l>%s</>; configuration updated.";
                logger.infof(cacertPattern, instance.connSettings.caBundleFile.doublyBackslashed);
                return true;
            }
            else
            {
                enum cacertPattern = "File saved as <l>%s</>.";
                logger.infof(cacertPattern, instance.connSettings.caBundleFile.doublyBackslashed);
                return false;  // let user supply --save
            }
        }
        else
        {
            return false;
        }
    }

    void downloadOpenSSL()
    {
        import std.file : mkdirRecurse, tempDir;
        import std.json : JSONException;
        import std.process : ProcessException;

        immutable temporaryDir = buildNormalizedPath(tempDir, "kameloso");
        mkdirRecurse(temporaryDir);

        enum jsonURL = "https://raw.githubusercontent.com/slproweb/opensslhashes/master/win32_openssl_hashes.json";
        immutable jsonFile = buildNormalizedPath(temporaryDir, "win32_openssl_hashes.json");
        immutable result = downloadFile(jsonURL, "manifest", jsonFile);
        if (*instance.abort) return;
        if (result != 0) return;

        try
        {
            import std.file : readText;
            import std.json : parseJSON;

            version(Win64)
            {
                immutable head = shouldDownloadOpenSSL1_1 ?
                    "Win64OpenSSL_Light-1_1" :
                    "Win64OpenSSL_Light-3_2";
            }
            else version(Win32)
            {
                immutable head = shouldDownloadOpenSSL1_1 ?
                    "Win32OpenSSL_Light-1_1" :
                    "Win32OpenSSL_Light-3_2";
            }
            else version(AArch64)
            {
                // Untested, might work?
                immutable head = shouldDownloadOpenSSL1_1 ?
                    "Win64ARMOpenSSL_Light-1_1" :
                    "Win64ARMOpenSSL_Light-3_2";
            }
            else
            {
                static assert(0, "Unsupported platform, please file a bug.");
            }

            const hashesJSON = parseJSON(readText(jsonFile));

            foreach (immutable filename, fileEntryJSON; hashesJSON["files"].object)
            {
                import std.algorithm.searching : endsWith, startsWith;

                if (filename.startsWith(head) && filename.endsWith(".msi"))
                {
                    import std.process : execute;

                    immutable msi = buildNormalizedPath(temporaryDir, filename);
                    immutable downloadResult = downloadFile(fileEntryJSON["url"].str, "OpenSSL installer", msi);
                    if (*instance.abort) return;
                    if (downloadResult != 0) break;

                    immutable string[3] command =
                    [
                        "msiexec",
                        "/i",
                        msi,
                    ];

                    logger.info("Launching <l>OpenSSL</> installer.");
                    immutable result = execute(command[]);

                    if (result.status != 0)
                    {
                        enum errorPattern = "Installation process exited with status <l>%d";
                        logger.errorf(errorPattern, result.status);

                        version(PrintStacktraces)
                        {
                            import std.stdio : stdout, writeln;
                            import std.string : chomp;

                            immutable output = result.output.chomp;

                            if (output.length)
                            {
                                writeln(output);
                                stdout.flush();
                            }
                        }
                    }
                    return;
                }
            }

            // If we're here, we couldn't find anything in the json
            // Drop down
            logger.error("Could not find <l>OpenSSL</> .msi to download");
        }
        catch (JSONException e)
        {
            enum pattern = "Error parsing file containing <l>OpenSSL</> download links: <l>%s";
            logger.errorf(pattern, e.msg);
        }
        catch (ProcessException e)
        {
            enum pattern = "Error starting <l>OpenSSL</> installer: <l>%s";
            logger.errorf(pattern, e.msg);
        }
    }

    bool retval;

    if (shouldDownloadCacert)
    {
        import kameloso.string : doublyBackslashed;
        import std.file : exists;

        resolveCacert();

        if (instance.connSettings.caBundleFile.exists && !instance.settings.force)
        {
            enum pattern = "Found certificate authority bundle file <l>%s</>; not downloading.";
            logger.infof(pattern, instance.connSettings.caBundleFile.doublyBackslashed);
        }
        else
        {
            retval = downloadCacert();
        }
    }

    if (*instance.abort) return retval;  // or false?

    if (shouldDownloadOpenSSL)
    {
        import kameloso.net : openSSLIsInstalled;

        if (!instance.settings.force && openSSLIsInstalled())
        {
            enum message = "Found <l>OpenSSL for Windows</> as already installed; not downloading.";
            logger.info(message);
        }
        else
        {
            downloadOpenSSL();
        }
    }

    return retval;
}
