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
import std.typecons : Flag, No, Yes;

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
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
        shouldDownloadCacert = Whether or not `cacert.pem` should be downloaded.
        shouldDownloadOpenSSL = Whether or not OpenSSL for Windows should be downloaded.

    Returns:
        `Yes.settingsTouched` if [kameloso.kameloso.Kameloso.settings|Kameloso.settings]
        were touched and the configuration file should be updated; `No.settingsTouched` if not.
 +/
auto downloadWindowsSSL(
    ref Kameloso instance,
    const Flag!"shouldDownloadCacert" shouldDownloadCacert,
    const Flag!"shouldDownloadOpenSSL" shouldDownloadOpenSSL)
{
    import kameloso.common : logger;
    import std.path : buildNormalizedPath;

    static int downloadFile(
        const string url,
        const string what,
        const string saveAs)
    {
        import std.format : format;
        import std.process : executeShell;

        enum pattern = "Downloading %s from <l>%s</>...";
        logger.infof(pattern, what, url);

        enum executePattern = `powershell -c "Invoke-WebRequest '%s' -OutFile '%s'"`;
        immutable command = executePattern.format(url, saveAs);
        immutable result = executeShell(command);

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

    Flag!"settingsTouched" retval;

    if (shouldDownloadCacert)
    {
        import kameloso.string : doublyBackslashed;
        import std.path : dirName;

        enum cacertURL = "http://curl.se/ca/cacert.pem";
        immutable configDir = instance.settings.configFile.dirName;
        immutable cacertFile = buildNormalizedPath(configDir, "cacert.pem");
        immutable result = downloadFile(cacertURL, "certificate bundle", cacertFile);
        if (*instance.abort) return No.settingsTouched;

        if (result == 0)
        {
            if (!instance.settings.force)
            {
                enum cacertPattern = "File saved as <l>%s</>; configuration updated.";
                logger.infof(cacertPattern, cacertFile.doublyBackslashed);
                instance.connSettings.caBundleFile = "cacert.pem";  // cacertFile
                retval = Yes.settingsTouched;
            }
            else
            {
                enum cacertPattern = "File saved as <l>%s</>.";
                logger.infof(cacertPattern, cacertFile.doublyBackslashed);
                instance.connSettings.caBundleFile = cacertFile;  // absolute path
                //retval = Yes.settingsTouched;  // let user supply --save
            }
        }
    }

    if (shouldDownloadOpenSSL)
    {
        import std.file : mkdirRecurse, tempDir;
        import std.json : JSONException;
        import std.process : ProcessException;

        immutable temporaryDir = buildNormalizedPath(tempDir, "kameloso");
        mkdirRecurse(temporaryDir);

        enum jsonURL = "https://raw.githubusercontent.com/slproweb/opensslhashes/master/win32_openssl_hashes.json";
        immutable jsonFile = buildNormalizedPath(temporaryDir, "win32_openssl_hashes.json");
        immutable result = downloadFile(jsonURL, "manifest", jsonFile);
        if (*instance.abort) return No.settingsTouched;
        if (result != 0) return retval;

        try
        {
            import std.file : readText;
            import std.json : parseJSON;

            const hashesJSON = parseJSON(readText(jsonFile));

            foreach (immutable filename, fileEntryJSON; hashesJSON["files"].object)
            {
                import std.algorithm.searching : endsWith, startsWith;

                version(Win64)
                {
                    enum head = "Win64OpenSSL_Light-1_";
                }
                else /*version(Win32)*/
                {
                    enum head = "Win32OpenSSL_Light-1_";
                }

                if (filename.startsWith(head) && filename.endsWith(".exe"))
                {
                    import std.process : execute;

                    immutable exeFile = buildNormalizedPath(temporaryDir, filename);
                    immutable downloadResult = downloadFile(fileEntryJSON["url"].str, "OpenSSL installer", exeFile);
                    if (*instance.abort) return No.settingsTouched;
                    if (downloadResult != 0) break;

                    logger.info("Launching installer.");
                    cast(void)execute([ exeFile ]);

                    return retval;
                }
            }

            logger.error("Could not find OpenSSL .exe to download");
            // Drop down and return
        }
        catch (JSONException e)
        {
            enum pattern = "Error parsing file containing OpenSSL download links: <l>%s";
            logger.errorf(pattern, e.msg);
        }
        catch (ProcessException e)
        {
            enum pattern = "Error starting installer: <l>%s";
            logger.errorf(pattern, e.msg);
        }
    }

    return retval;
}
