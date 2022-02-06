
module lu.traits;

enum MixinScope
{
    function_  }




template MixinConstraints()
{
}


template isSerialisable(alias sym)
{
        alias T = typeof(sym);

        enum isSerialisable =
            !__traits(isTemplate, T) ;
}


enum isTrulyString(S) = is(S == string) ;


template UnqualArray(QualType)
{
}


enum isStruct;




    
    public import std;
