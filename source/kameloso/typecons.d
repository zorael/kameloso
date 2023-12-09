/++
    This module is currently empty now that `UnderscoreOpDispatcher` was upstreamed
    into `lu`. It is kept for backwards-compatibility reasons, and will be removed
    in a future release.

    See_Also:
        https://github.com/zorael/lu/blob/master/source/lu/typecons.d

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.typecons;

private:

public:

/+
    Backwards-compatibility alias to [lu.typecons.UnderscoreOpDispatcher].
 +/
deprecated("Use `lu.typecons.UnderscoreOpDispatcher` instead")
import lu.typecons : UnderscoreOpDispatcher;
