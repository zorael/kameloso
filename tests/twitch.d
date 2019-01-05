import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

version(TwitchSupport):

unittest
{
    IRCParser parser;

    with (parser.client)
    {
        nickname = "kameloso";
        user = "kameloso!";
        server.address = "irc.chat.twitch.tv";
    }

    {
        immutable event = parser.toIRCEvent(":tmi.twitch.tv 004 kameloso :-");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_MYINFO), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((num == 4), num.to!string);
        }
    }

    with (parser.client)
    {
        assert((server.daemon == IRCServer.Daemon.twitch), Enum!(IRCServer.Daemon).toString(server.daemon));
        assert((server.network == "Twitch"), server.network);
        assert((server.daemonstring == "Twitch"), server.daemonstring);
        assert((server.maxNickLength == 25), server.maxNickLength.to!string);
        assert((server.prefixchars == ['@':'o']), server.prefixchars.to!string);
        assert((server.prefixes == "o"), server.prefixes);
    }

    immutable e18 = parser.toIRCEvent(":tmi.twitch.tv HOSTTARGET #lirik :h1z1 -");
    with (e18)
    {
        assert((sender.address == "tmi.twitch.tv"), sender.address);
        assert((type == IRCEvent.Type.TWITCH_HOSTSTART), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#lirik"), channel);
        assert((content == "h1z1"), content);
        assert(!count, count.to!string);
        assert(!num, num.to!string);
    }

    immutable e19 = parser.toIRCEvent(":tmi.twitch.tv HOSTTARGET #lirik :- 178");
    with (e19)
    {
        assert((sender.address == "tmi.twitch.tv"), sender.address);
        assert((type == IRCEvent.Type.TWITCH_HOSTEND), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#lirik"), channel);
        assert((count == 178), count.to!string);
        assert(!num, num.to!string);
    }

    immutable e20 = parser.toIRCEvent(":tmi.twitch.tv HOSTTARGET #lirik :chu8 270");
    with (e20)
    {
        assert((sender.address == "tmi.twitch.tv"), sender.address);
        assert((type == IRCEvent.Type.TWITCH_HOSTSTART), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#lirik"), channel);
        assert((content == "chu8"), content);
        assert((count == 270), count.to!string);
        assert(!num, num.to!string);
    }

    {
        immutable event = parser.toIRCEvent("@badges=subscriber/3;color=;display-name=asdcassr;emotes=560489:0-6,8-14,16-22,24-30/560510:39-46;id=4d6bbafb-427d-412a-ae24-4426020a1042;mod=0;room-id=23161357;sent-ts=1510059590512;subscriber=1;tmi-sent-ts=1510059591528;turbo=0;user-id=38772474;user-type= :asdcsa!asdcss@asdcsd.tmi.twitch.tv PRIVMSG #lirik :lirikFR lirikFR lirikFR lirikFR :sled: lirikLUL");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == CHAN), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "asdcsa"), sender.nickname);
            assert((sender.ident == "asdcss"), sender.ident);
            assert((sender.address == "asdcsd.tmi.twitch.tv"), sender.address);
            assert((sender.class_ != IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#lirik"), channel);
            assert((content == "lirikFR lirikFR lirikFR lirikFR :sled: lirikLUL"), content);
            assert((tags == "badges=subscriber/3;color=;display-name=asdcassr;emotes=560489:0-6,8-14,16-22,24-30/560510:39-46;id=4d6bbafb-427d-412a-ae24-4426020a1042;mod=0;room-id=23161357;sent-ts=1510059590512;subscriber=1;tmi-sent-ts=1510059591528;turbo=0;user-id=38772474;user-type="), tags);
        }
    }
    {
        immutable event = parser.toIRCEvent("@broadcaster-lang=;emote-only=0;followers-only=-1;mercury=0;r9k=0;room-id=22216721;slow=0;subs-only=0 :tmi.twitch.tv ROOMSTATE #zorael");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ROOMSTATE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#zorael"), channel);
            assert((tags == "broadcaster-lang=;emote-only=0;followers-only=-1;mercury=0;r9k=0;room-id=22216721;slow=0;subs-only=0"), tags);
        }
    }
    {
        immutable event = parser.toIRCEvent(":tmi.twitch.tv CAP * LS :twitch.tv/tags twitch.tv/commands twitch.tv/membership");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == CAP), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "twitch.tv/tags twitch.tv/commands twitch.tv/membership"), content);
            assert((aux == "LS"), aux);
        }
    }
    {
        immutable event = parser.toIRCEvent(":tmi.twitch.tv USERSTATE #zorael");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == USERSTATE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert(!content.length, content);
            assert((channel == "#zorael"), channel);
        }
    }
    {
        immutable event = parser.toIRCEvent(":tmi.twitch.tv ROOMSTATE #zorael");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ROOMSTATE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert(!content.length, content);
            assert((channel == "#zorael"), channel);
        }
    }
    {
        immutable event = parser.toIRCEvent(":tmi.twitch.tv HOSTTARGET #andymilonakis :zombie_barricades -");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == TWITCH_HOSTSTART), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#andymilonakis"), channel);
            assert((content == "zombie_barricades"), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":tmi.twitch.tv USERNOTICE #drdisrespectlive :ooooo weee, it's a meeeee, Moweee!");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == USERNOTICE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#drdisrespectlive"), channel);
            assert((content == "ooooo weee, it's a meeeee, Moweee!"), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":tmi.twitch.tv USERNOTICE #lirik");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == USERNOTICE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#lirik"), channel);
        }
    }
    {
        immutable event = parser.toIRCEvent(":tmi.twitch.tv CLEARCHAT #channel :user");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == CLEARCHAT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#channel"), channel);
            assert((target.nickname == "user"), target.nickname);
        }
    }
    {
        immutable event = parser.toIRCEvent(":tmi.twitch.tv RECONNECT");
        with (event)
        {
            assert((type == IRCEvent.Type.RECONNECT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
        }
    }
    {
        immutable event = parser.toIRCEvent(":kameloso!kameloso@kameloso.tmi.twitch.tv JOIN p4wnyhof");
        with (event)
        {
            assert((type == IRCEvent.Type.SELFJOIN), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "kameloso"), sender.nickname);
            assert((sender.ident == "kameloso"), sender.ident);
            assert((sender.address == "kameloso.tmi.twitch.tv"), sender.address);
            assert((channel == "p4wnyhof"), channel);
        }
    }
    {
        immutable event = parser.toIRCEvent(":kameloso!kameloso@kameloso.tmi.twitch.tv PART p4wnyhof");
        with (event)
        {
            assert((type == IRCEvent.Type.SELFPART), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "kameloso"), sender.nickname);
            assert((sender.ident == "kameloso"), sender.ident);
            assert((sender.address == "kameloso.tmi.twitch.tv"), sender.address);
            assert((channel == "p4wnyhof"), channel);
        }
    }
}
