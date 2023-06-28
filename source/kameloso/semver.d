/++
    SemVer information about the current release.

    Contains only definitions, no code. Helps importing projects tell what
    features are available.

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.semver;


/// SemVer versioning of this build.
enum KamelosoSemVer
{
    majorVersion = 3,  /// SemVer major version of the program.
    minorVersion = 9,  /// SemVer minor version of the program.
    patchVersion = 0,  /// SemVer patch version of the program.
}


/// Pre-release SemVer subversion of this build.
enum KamelosoSemVerPrerelease = string.init;
