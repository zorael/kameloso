/++
    Bits and bobs that download SSL libraries and related necessities on Windows.
 +/
module kameloso.ssldownloads;

version(Windows):

private:

public:

void downloadWindowsSSL(const bool shouldDownloadCacert, const bool shouldDownloadOpenSSL)
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
        import std.file : tempDir;
        import std.path : buildNormalizedPath;
        import std.process : spawnProcess;
        import std.stdio : File;

        immutable urlFileName = buildNormalizedPath(tempDir, "kameloso", "link.url");

        {
            auto urlFile = File(urlFileName, "w");
            urlFile.writeln("[InternetShortcut]\nURL=", url);
        }

        immutable string[2] browserCommand = [ "explorer", urlFileName ];
        auto nulFile = File("NUL", "r+");
        return spawnProcess(browserCommand[], nulFile, nulFile, nulFile);
    }

    if (shouldDownloadCacert)
    {
        import kameloso.platform : cbd = configurationBaseDirectory;
        import std.path : buildNormalizedPath;

        enum url = "http://curl.se/ca/cacert.pem";
        enum pattern = "<l>cacert.pem</>: Save it anywhere, though preferably in <l>%s</>.";
        enum pathPattern = "That way you don't have to enter its full path " ~
            "in the configuration file (<l>cacert.pem</> will be enough).";
        enum configPattern = "Open the configuration file by passing <l>--gedit</>.";

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
        enum versionPattern = "<l>OpenSSL</>: You want <l>v1.1.1n Light</> (or later), not <l>v3.0.x</>.";
        enum installPattern = "Remember to install to <l>Windows system directories</> when asked.";

        logger.info(versionPattern.expandTags(LogLevel.info));
        logger.info(installPattern.expandTags(LogLevel.info));
        openSSLBrowser = openURL(url);
    }
}
