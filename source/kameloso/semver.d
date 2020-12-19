/++
    SemVer information about the current release.

    Contains only definitions, no code. Helps importing projects tell what
    features are available.
 +/
module kameloso.semver;


/// SemVer versioning of this build.
enum KamelosoSemVer
{
    majorVersion = 2,  /// SemVer major version of the program.
    minorVersion = 0,  /// SemVer minor version of the program.
    patchVersion = 0,  /// SemVer patch version of the program.
}


/// Pre-release SemVer subversion of this build.
enum KamelosoSemVerPrerelease = "rc.3";
