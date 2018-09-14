/++
 +  This module contains functions that in some way or another manipulates
 +  struct and class instances.
 +/
module kameloso.objmanip;

import kameloso.uda;

public import kameloso.meld;

@safe:


// setMemberByName
/++
 +  Given a struct/class object, sets one of its members by its string name to a
 +  specified value.
 +
 +  It does not currently recurse into other struct/class members.
 +
 +  Example:
 +  ---
 +  IRCBot bot;
 +
 +  bot.setMemberByName("nickname", "kameloso");
 +  bot.setMemberByName("address", "blarbh.hlrehg.org");
 +  bot.setMemberByName("special", "false");
 +
 +  assert(bot.nickname == "kameloso");
 +  assert(bot.address == "blarbh.hlrehg.org");
 +  assert(!bot.special);
 +  ---
 +
 +  Params:
 +      thing = Reference object whose members to set.
 +      memberToSet = String name of the thing's member to set.
 +      valueToSet = String contents of the value to set the member to; string
 +          even if the member is of a different type.
 +
 +  Returns:
 +      `true` if a member was found and set, `false` if not.
 +/
bool setMemberByName(Thing)(ref Thing thing, const string memberToSet, const string valueToSet)
{
    return false;
}


// zeroMembers
/++
 +  Zeroes out members of a passed struct that only contain the value of the
 +  passed `emptyToken`. If a string then its contents are thus, if an array
 +  with only one element then if that is thus.
 +
 +  Params:
 +      emptyToken = What string to look for when zeroing out members.
 +      thing = Reference to a struct whose members to iterate over, zeroing.
 +/
void zeroMembers(string emptyToken = "-", Thing)(ref Thing thing)
if (is(Thing == struct))
{
}


// deepSizeof
/++
 +  Naïvely sums up the size of something in memory.
 +
 +  It enumerates all fields in classes and structs and recursively sums up the
 +  space everything takes. It's naïve in that it doesn't take into account
 +  that some arrays and such may have been allocated in a larger chunk than the
 +  length of the array itself.
 +
 +  Example:
 +  ---
 +  struct Foo
 +  {
 +      string asdf = "qwertyuiopasdfghjklxcvbnm";
 +      int i = 42;
 +      float f = 3.14f;
 +  }
 +
 +  Foo foo;
 +  writeln(foo.deepSizeof);
 +  ---
 +
 +  Params:
 +      thing = Object to enumerate and add up the members of.
 +
 +  Returns:
 +      The calculated *minimum* number of bytes allocated for the passed
 +      object.
 +/
uint deepSizeof(T)(const T thing) pure @nogc @safe @property
{
    return 0;
}
