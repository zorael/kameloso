/++
    Package for the Printer plugin modules.

    See_Also:
        [kameloso.plugins.printer.base],
        [kameloso.plugins.printer.formatting],
        [kameloso.plugins.printer.logging]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.printer;

version(WithPrinterPlugin):

public:

import kameloso.plugins.printer.base;
import kameloso.plugins.printer.formatting;
import kameloso.plugins.printer.logging;
