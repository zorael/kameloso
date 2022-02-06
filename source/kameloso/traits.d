
module kameloso.traits;

private template longestMemberNameImpl()
{
    

    enum longestMemberNameImpl = string.init;
}




alias longestMemberName(Things...) = longestMemberNameImpl!();







alias longestUnserialisableMemberName(Things...) = longestMemberNameImpl!();







private template longestMemberTypeNameImpl()
{
    
    enum longestMemberTypeNameImpl = string.init;
}




alias longestMemberTypeName(Things...) = longestMemberTypeNameImpl!();







alias longestUnserialisableMemberTypeName(Things...) = longestMemberTypeNameImpl!();



