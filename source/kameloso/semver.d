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


/++
    SemVer versioning of this build.
 +/
enum KamelosoSemVer
{
    /++
        SemVer major version of the program.
     +/
    major = 3,

    /++
        SemVer minor version of the program.
     +/
    minor = 12,

    /++
        SemVer patch version of the program.
     +/
    patch = 0,

    /++
        SemVer version of the program. Deprecated; use `KamelosoSemVer.major` instead.
     +/
    deprecated("Use `KamelosoSemVer.major` instead. This symbol will be removed in a future release.")
    majorVersion = major,

    /++
        SemVer version of the program. Deprecated; use `KamelosoSemVer.minor` instead.
     +/
    deprecated("Use `KamelosoSemVer.minor` instead. This symbol will be removed in a future release.")
    minorVersion = minor,

    /++
        SemVer version of the program. Deprecated; use `KamelosoSemVer.patch` instead.
     +/
    deprecated("Use `KamelosoSemVer.patch` instead. This symbol will be removed in a future release.")
    patchVersion = patch,
}


/++
    Pre-release SemVer subversion of this build.
 +/
enum KamelosoSemVerPrerelease = string.init;
