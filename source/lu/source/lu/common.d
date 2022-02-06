
module lu.common;

@safe:




enum Next
{
    continue_,     
    retry,         
    returnSuccess, 
    returnFailure, 
    crash,         
}




class FileTypeMismatchException : Exception
{
    
    this(string message,
string ,
ushort ,
string )     {
        super(message);
    }
}




uint sharedDomains(string one, string other) {
    return one.length > other.length;
}


