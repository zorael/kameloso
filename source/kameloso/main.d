module kameloso.main;

import kameloso.common;
import kameloso.constants;

import std.stdio;

void printVersionInfo(BashForeground colourCode = BashForeground.default_)
{
    writefln("%skameloso IRC bot v%s, built %s\n$ git clone %s.git%s",
        colourCode.colour,
        cast(string)KamelosoInfo.version_,
        cast(string)KamelosoInfo.built,
        cast(string)KamelosoInfo.source,
        BashForeground.default_.colour);
}

void main() { }
