/++
    Bits and bobs that download SSL libraries and related necessities on Windows.
 +/
module kameloso.ssldownloads;

version(Windows):

private:

import std.typecons : Flag, No, Yes;

public:


// downloadWindowsSSL
/++
    Downloads OpenSSL for Windows and/or a `cacert.pem` certificate bundle from
    the cURL project, extracted from Mozilla Firefox.

    Params:
        shouldDownloadCacert = Whether or not `cacert.pem` should be downloaded.
        shouldDownloadOpenSSL = Whether or not OpenSSL for Windows should be downloaded.
 +/
void downloadWindowsSSL(
    const Flag!"shouldDownloadCacert" shouldDownloadCacert,
    const Flag!"shouldDownloadOpenSSL" shouldDownloadOpenSSL)
{
    import kameloso.common : expandTags, logger;
    import kameloso.logger : LogLevel;
    import std.process : Pid, wait;

    Pid cacertBrowser;
    Pid openSSLBrowser;

    scope(exit)
    {
        if (cacertBrowser) wait(cacertBrowser);
        if (openSSLBrowser) wait(openSSLBrowser);
    }

    static Pid openURL(const string url)
    {
        import std.array : replace;
        import std.file : tempDir;
        import std.path : buildNormalizedPath;
        import std.process : spawnProcess;
        import std.stdio : File;

        // Save the filename as the URL sans "https://"
        assert(((url.length > 8) && (url[0..8] == "https://")), url);
        immutable basename = url[8..$].replace('/', '_') ~ ".url";
        immutable urlFileName = buildNormalizedPath(tempDir, "kameloso", basename);

        {
            auto urlFile = File(urlFileName, "w");
            urlFile.writeln("[InternetShortcut]\nURL=", url);
        }

        immutable string[2] browserCommand = [ "explorer", urlFileName ];
        auto nulFile = File("NUL", "r+");
        return spawnProcess(browserCommand[], nulFile, nulFile, nulFile);
    }

    logger.info("Opening your web browser to download given files...");

    if (shouldDownloadCacert)
    {
        import kameloso.platform : cbd = configurationBaseDirectory;
        import std.path : buildNormalizedPath;

        enum url = "https://curl.se/ca/cacert.pem";
        enum pattern = "<l>cacert.pem</>: Save it anywhere, though preferably in <l>%APPDATA%/kameloso</>. [<l>%s</>]";
        enum pathPattern = "That way you don't have to enter its full path in the configuration file.";
        enum configPattern = "Tip: Open the configuration file by passing <l>--gedit</>.";

        immutable kamelosoDir = buildNormalizedPath(cbd, "kameloso");

        logger.infof(pattern.expandTags(LogLevel.info), kamelosoDir);
        logger.info(pathPattern.expandTags(LogLevel.info));
        logger.info(configPattern.expandTags(LogLevel.info));
        cacertBrowser = openURL(url);
    }

    if (shouldDownloadCacert && shouldDownloadOpenSSL)
    {
        logger.trace("---");
    }

    if (shouldDownloadOpenSSL)
    {
        enum url = "https://slproweb.com/products/Win32OpenSSL.html";
        enum versionPattern = "<l>OpenSSL</>: You want <l>v1.1.1 Light</>, not <l>v3.0.x</>.";
        enum installPattern = "Remember to install to <l>Windows system directories</> when asked.";

        logger.info(versionPattern.expandTags(LogLevel.info));
        logger.info(installPattern.expandTags(LogLevel.info));
        openSSLBrowser = openURL(url);
    }
}
