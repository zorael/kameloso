module kameloso.plugins.notes;

import std.json;

JSONValue loadNotes(string filename)
{
    try
    {
        return parseJSON(filename);
    }
    catch (Exception e)
    {
        return emptyNotes;
    }
}

JSONValue emptyNotes()
{
    JSONValue newJSON;
    return newJSON;
}
