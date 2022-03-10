/++
    Package for the Admin plugin modules.

    See_Also:
        [kameloso.plugins.admin.base|admin.base]
        [kameloso.plugins.admin.classifiers|admin.classifiers]
        [kameloso.plugins.admin.debugging|admin.debugging]
 +/
module kameloso.plugins.admin;

version(WithAdminPlugin):

public:

import kameloso.plugins.admin.base;
import kameloso.plugins.admin.classifiers;
debug import kameloso.plugins.admin.debugging;
