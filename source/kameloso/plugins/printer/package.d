/++
    Package for the Printer plugin modules.

    See_Also:
        $(REF kameloso.plugins.common.base),
        $(REF kameloso.plugins.common.formatting),
        $(REF kameloso.plugins.common.logging)
 +/
module kameloso.plugins.printer;

version(WithPlugins):
version(WithPrinterPlugin):

public:

import kameloso.plugins.printer.base;
import kameloso.plugins.printer.formatting;
import kameloso.plugins.printer.logging;
