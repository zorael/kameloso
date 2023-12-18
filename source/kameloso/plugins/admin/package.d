/++
    Package for the Admin plugin modules.

    See_Also:
        [kameloso.plugins.admin.base],
        [kameloso.plugins.admin.classifiers],
        [kameloso.plugins.admin.debugging]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.admin;

version(WithAdminPlugin):
debug version = Debug;

public:

import kameloso.plugins.admin.base;
import kameloso.plugins.admin.classifiers;
version(Debug) import kameloso.plugins.admin.debugging;
