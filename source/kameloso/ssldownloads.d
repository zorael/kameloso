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

version(Windows) version = WindowsPlatform;
version(unittest) version = WindowsPlatform;

version(WindowsPlatform):

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
        `true` if [kameloso.kameloso.Kameloso.coreSettings|Kameloso.coreSettings]
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
        const string saveAs,
        const size_t sizeInBytes = 0)
    {
        import std.process : execute;

        if (sizeInBytes)
        {
            enum pattern = "Downloading %s from <l>%s</>... (<l>%.1f Mb</>)";
            immutable sizeInMbytes = sizeInBytes / 1024.0 / 1024;
            logger.infof(pattern, what, url, sizeInMbytes);

            if (sizeInMbytes > 100)
            {
                logger.info("This may take a while. Please wait.");
            }
        }
        else
        {
            enum pattern = "Downloading %s from <l>%s</>...";
            logger.infof(pattern, what, url);
        }

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
            // Can't use instance.coreSettings.configDirectory; it hasn't been resolved yet
            instance.connSettings.caBundleFile = buildNormalizedPath(
                instance.coreSettings.configFile.dirName,
                "cacert.pem");
        }
    }

    auto downloadCacert()
    {
        import kameloso.string : doublyBackslashed;

        enum cacertURL = "https://curl.se/ca/cacert.pem";
        immutable result = downloadFile(
            url: cacertURL,
            what: "certificate bundle",
            saveAs: instance.connSettings.caBundleFile);

        if (*instance.abort) return false;

        if (result == 0)
        {
            if (!instance.coreSettings.force)
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

        version(Win64)
        {
            enum arch = "INTEL";
            enum bits = 64;
        }
        else version(Win32)
        {
            enum arch = "INTEL";
            enum bits = 32;
        }
        else version(AArch64)
        {
            // Untested, might work?
            enum arch = "ARM";
            enum bits = 64;
        }
        else version(unittest)
        {
            enum arch = string.init;
            enum bits = int.init;
        }
        else
        {
            static assert(0, "Unsupported platform, please file a bug.");
        }

        immutable temporaryDir = buildNormalizedPath(tempDir, "kameloso");
        mkdirRecurse(temporaryDir);

        enum jsonURL = "https://raw.githubusercontent.com/slproweb/opensslhashes/master/win32_openssl_hashes.json";
        immutable jsonFile = buildNormalizedPath(temporaryDir, "win32_openssl_hashes.json");
        immutable manifestResult = downloadFile(
            url: jsonURL,
            what: "file manifest",
            saveAs: jsonFile);

        if (*instance.abort) return;
        if (manifestResult != 0) return;

        try
        {
            import std.file : readText;
            import std.json : parseJSON;
            import std.process : execute;

            string topFilename;
            uint topVersionMinor;
            uint topVersionPatch;
            size_t topSize;

            // FIXME: asdf
            const manifestJSON = parseJSON(readText(jsonFile));
            const fileEntriesJSON = "files" in manifestJSON;

            /+
                Figure out the latest version by finding the entry with the
                highest values in the "basever" string in its JSON.
             +/
            foreach (immutable filename, const fileEntryJSON; (*fileEntriesJSON).object)
            {
                import lu.string : advancePast;
                import std.conv : to;

                if ((fileEntryJSON["arch"].str != arch) || (fileEntryJSON["bits"].integer != bits)) continue;

                immutable versionString = fileEntryJSON["basever"].str;
                string slice = versionString;  // mutable

                // "basever": "1.1.1"
                // "basever": "3.3.2"
                // "basever": "3.4.0"

                // Could use formattedRead but where's the elegance in that
                immutable versionMajor = slice.advancePast('.').to!uint;

                if (shouldDownloadOpenSSL1_1 && (versionMajor != 1)) continue;

                immutable versionMinor = slice.advancePast('.').to!uint;
                immutable versionPatch = slice.to!uint;

                if (versionMinor > topVersionMinor)
                {
                    topFilename = filename;
                    topVersionMinor = versionMinor;
                    topVersionPatch = versionPatch;
                    topSize = fileEntryJSON["size"].integer;
                }
                else if (
                    (versionMinor == topVersionMinor) &&
                    (versionPatch > topVersionPatch))
                {
                    topFilename = filename;
                    topVersionPatch = versionPatch;
                    topSize = fileEntryJSON["size"].integer;
                }
            }

            if (!topFilename.length)
            {
                // We couldn't find anything in the json
                logger.error("Could not find <l>OpenSSL</> .msi to download");
                return;
            }

            const topFileEntryJSON = (*fileEntriesJSON)[topFilename];
            immutable msiPath = buildNormalizedPath(temporaryDir, topFilename);
            immutable downloadResult = downloadFile(
                url: topFileEntryJSON["url"].str,
                what: "OpenSSL installer",
                saveAs: msiPath,
                sizeInBytes: topSize);

            if (*instance.abort) return;
            if (downloadResult != 0) return;

            immutable string[3] command =
            [
                "msiexec",
                "/i",
                msiPath,
            ];

            logger.info("Launching <l>OpenSSL</> installer.");
            logger.info("Choose to install to <l>Windows system directories</> when asked.");

            immutable msiExecResult = execute(command[]);

            if (msiExecResult.status != 0)
            {
                enum errorPattern = "Installation process exited with status <l>%d";
                logger.errorf(errorPattern, msiExecResult.status);

                version(PrintStacktraces)
                {
                    import std.stdio : stdout, writeln;
                    import std.string : chomp;

                    immutable output = msiExecResult.output.chomp;

                    if (output.length)
                    {
                        writeln(output);
                        stdout.flush();
                    }
                }
            }
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

        if (instance.connSettings.caBundleFile.exists && !instance.coreSettings.force)
        {
            enum pattern = "Found certificate authority bundle file <l>%s</>; not downloading.";
            logger.infof(pattern, instance.connSettings.caBundleFile.doublyBackslashed);
        }
        else
        {
            retval = downloadCacert();
        }
    }

    if (*instance.abort) return false;

    if (shouldDownloadOpenSSL)
    {
        import kameloso.net : openSSLIsInstalled;

        if (!instance.coreSettings.force && openSSLIsInstalled())
        {
            enum message = "Found <l>OpenSSL for Windows</> as already installed; not downloading.";
            logger.info(message);
        }
        else
        {
            // Downloading OpenSSL is not cause for a settings update
            /*retval |=*/ downloadOpenSSL();
        }
    }

    return retval;
}
