module kameloso.logger;

import std.experimental.logger;

class KamelosoLogger : Logger
{
    this(LogLevel lv)
    {
        super(lv);
    }

    private string tintImpl(LogLevel level)() const @property
    {
        return string.init;
    }

    alias infotint = tintImpl!(LogLevel.info);
}
