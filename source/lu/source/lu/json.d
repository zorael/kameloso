
module lu.json;

import std;
struct JSONStorage
{
    
    JSONValue storage;

    alias storage this;

    
    enum KeyOrderStrategy
    {
        
        passthrough,  

        
        inGivenOrder,
    }

    
    
    void reset()     {
    }

    
    
    void load(string )     {
    }


    
    
    void save(KeyOrderStrategy strategy = KeyOrderStrategy.passthrough)
        (string , const string[] = string[].init)     {
    }


}


void populateFromJSON(T)(T target, JSONValue json) {
    static if (isAssociativeArray!T )
    {
            const aggregate = json.objectNoRef;
        foreach (ikey, valJSON; aggregate)
            populateFromJSON(target[ikey], valJSON);
        
    }
    else
        with (JSONType)
        final switch (json.type)
        {
        case string:
            target = json.str;

            break;

        case integer:
            
            target = integer.to!T;
            break;

        case uinteger:
            
            target = uinteger.to!T;
            break;

        case float_:
            target = json.floating.to!T;
            break;

        case true_:
        case false_:
            target = json.boolean.to!T;
            break;

        case null_:
            
            break;

        case object:
        case array:
            import std;
(format(stringof, json.type));
        }
}


