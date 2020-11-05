/++
    Package for the Admin plugin modules.

    See_Also:
        $(REF kameloso.plugins.admin.base),
        $(REF kameloso.plugins.admin.classifiers),
        $(REF kameloso.plugins.admin.debugging)
 +/
module kameloso.plugins.admin;

version(WithPlugins):
version(WithAdminPlugin):

public:

import kameloso.plugins.admin.base;
import kameloso.plugins.admin.classifiers;
debug import kameloso.plugins.admin.debugging;
