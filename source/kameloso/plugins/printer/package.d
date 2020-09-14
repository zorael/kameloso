/++
    Package for the Printer plugin modules.
 +/
module kameloso.plugins.printer;

version(WithPlugins):
version(WithPrinterPlugin):

public import kameloso.plugins.printer.base;
public import kameloso.plugins.printer.formatting;
public import kameloso.plugins.printer.logging;
