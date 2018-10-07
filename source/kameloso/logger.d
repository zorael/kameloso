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

    alias logtint = tintImpl!(LogLevel.all);
    alias infotint = tintImpl!(LogLevel.info);
    alias warningtint = tintImpl!(LogLevel.warning);
    alias errortint = tintImpl!(LogLevel.error);
    alias fataltint = tintImpl!(LogLevel.fatal);
}
