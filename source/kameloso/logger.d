
module kameloso.logger;

import std.experimental.logger ;

class KamelosoLogger : Logger
{
        import kameloso.bash : BashForeground, colour;

    bool brightTerminal;   

    
    this(LogLevel lv )
    {
        super(lv);
    }

    static tint(LogLevel , bool bright)
    {
        return bright ;
    }

    
    
    pragma(msg, "DustMiteNoRemoveStart");
    version(Colours)
    private string tintImpl(LogLevel level)() const @property
    {
        version(CtTints)
        {
            if (brightTerminal)
            {
                enum ctTint = tint(level, true).colour;
                return ctTint;
            }
            else
            {
                enum ctTint = tint(level, false).colour;
                return ctTint;
            }
        }
        else
        {
            return tint(level, brightTerminal).colour;
        }
    }

    version(Colours)
    {
        
        alias logtint = tintImpl!(LogLevel.all);

        
        alias infotint = tintImpl!(LogLevel.info);

        
        alias warningtint = tintImpl!(LogLevel.warning);

        
        alias errortint = tintImpl!(LogLevel.error);

        
        alias fataltint = tintImpl!(LogLevel.fatal);
    }
    pragma(msg, "DustMiteNoRemoveStop");

}


