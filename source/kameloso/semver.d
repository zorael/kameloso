/++
    SemVer information about the current release.

    Contains only definitions, no code. Helps importing projects tell what
    features are available.
 +/
module kameloso.semver;


/// SemVer versioning of this build.
enum KamelosoSemVer
{
    majorVersion = 3,  /// SemVer major version of the program.
    minorVersion = 4,  /// SemVer minor version of the program.
    patchVersion = 2,  /// SemVer patch version of the program.
}


/// Pre-release SemVer subversion of this build.
enum KamelosoSemVerPrerelease = string.init;
