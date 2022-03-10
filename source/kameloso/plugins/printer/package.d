/++
    Package for the Printer plugin modules.

    See_Also:
        [kameloso.plugins.printer.base|printer.base]
        [kameloso.plugins.printer.formatting|printer.formatting]
        [kameloso.plugins.printer.logging|printer.logging]
 +/
module kameloso.plugins.printer;

version(WithPrinterPlugin):

public:

import kameloso.plugins.printer.base;
import kameloso.plugins.printer.formatting;
import kameloso.plugins.printer.logging;
