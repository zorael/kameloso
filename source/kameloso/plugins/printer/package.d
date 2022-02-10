/++
    Package for the Printer plugin modules.

    See_Also:
        [kameloso.plugins.common.misc],
        [kameloso.plugins.common.formatting],
        [kameloso.plugins.common.logging]
 +/
module kameloso.plugins.printer;

version(WithPrinterPlugin):

public:

import kameloso.plugins.printer.base;
import kameloso.plugins.printer.formatting;
import kameloso.plugins.printer.logging;
