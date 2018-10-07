import std.experimental.logger;

Logger logger;

void main()
{
    import kameloso.logger;
    string infotint = (cast(KamelosoLogger)logger).infotint;
}
