/++
    Tables and enums of data used in various places.

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.tables;


// trueThenFalse
/++
    As the name suggests, a `bool[2]` with the values `true`, then `false`.

    Has its uses when you want to `foreach` over something twice.
 +/
static immutable bool[2] trueThenFalse = [ true, false ];


// HTTPVerb
/++
    Enum of HTTP verbs.
 +/
enum HTTPVerb
{
    /++
        init state.
     +/
    unset,

    /++
        HTTP GET.
     +/
    get,

    /++
        HTTP POST.
     +/
    post,

    /++
        HTTP PUT.
     +/
    put,

    /++
        HTTP PATCH.
     +/
    patch,

    /++
        HTTP DELETE.
     +/
    delete_,

    /++
        Unsupported HTTP verb.
     +/
    unsupported,
}


// getHTTPResponseCodeText
/++
    Returns the text associated with an HTTP response code.

    Params:
        code = HTTP response code.

    Returns:
        The text associated with the HTTP response code, or "(Unknown HTTP
        response)" if the code is not recognized.
 +/
auto getHTTPResponseCodeText(const uint code)
{
    switch (code)
    {
    case 0:
        return "(unset)";

    case 1:
    ..
    case 5:
        return "SSL library error";

    case 100: return "Continue";
    case 101: return "Switching Protocols";
    case 102: return "Processing";
    case 103: return "Early Hints";

    case 200: return "OK";
    case 201: return "Created";
    case 202: return "Accepted";
    case 203: return "Non-Authoritative Information";
    case 204: return "No Content";
    case 205: return "Reset Content";
    case 206: return "Partial Content";
    case 207: return "Multi-Status";
    case 208: return "Already Reported";
    case 226: return "IM Used";

    case 300: return "Multiple Choices";
    case 301: return "Moved Permanently";
    case 302: return "Found";
    case 303: return "See Other";
    case 304: return "Not Modified";
    case 305: return "Use Proxy";
    case 306: return "Switch Proxy";
    case 307: return "Temporary Redirect";
    case 308: return "Permanent Redirect";

    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 402: return "Payment Required";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 406: return "Not Acceptable";
    case 407: return "Proxy Authentication Required";
    case 408: return "Request Timeout";
    case 409: return "Conflict";
    case 410: return "Gone";
    case 411: return "Length Required";
    case 412: return "Precondition Failed";
    case 413: return "Payload Too Large";
    case 414: return "URI Too Long";
    case 415: return "Unsupported Media Type";
    case 416: return "Range Not Satisfiable";
    case 417: return "Expectation Failed";
    case 418: return "I'm a teapot";
    case 421: return "Misdirected Request";
    case 422: return "Unprocessable Entity";
    case 423: return "Locked";
    case 424: return "Failed Dependency";
    case 425: return "Too Early";
    case 426: return "Upgrade Required";
    case 428: return "Precondition Required";
    case 429: return "Too Many Requests";
    case 431: return "Request Header Fields Too Large";
    case 451: return "Unavailable For Legal Reasons";

    case 500: return "Internal Server Error";
    case 501: return "Not Implemented";
    case 502: return "Bad Gateway";
    case 503: return "Service Unavailable";
    case 504: return "Gateway Timeout";
    case 505: return "HTTP Version Not Supported";
    case 506: return "Variant Also Negotiates";
    case 507: return "Insufficient Storage";
    case 508: return "Loop Detected";
    case 510: return "Not Extended";
    case 511: return "Network Authentication Required";

    case 218: return "This is fine";
    case 419: return "Page Expired";
    //case 420: return "Method Failure";
    case 420: return "Enhance your calm";
    //case 430: return "Request Header Fields Too Large";
    case 430: return "Shopify Security Rejection";
    case 450: return "Blocked by Windows Parental Controls";
    case 498: return "Invalid Token";
    case 499: return "Token Required";
    case 509: return "Bandwidth Limit Exceeded";
    case 529: return "Site is overloaded";
    //case 530: return "Site is frozen";
    case 530: return "Origin DNS Error";
    case 540: return "Temporarily Disabled";
    case 598: return "Network Rea Timeout Error";
    case 599: return "Network Connect Timeout Error";
    case 783: return "Unexpected Token";

    case 440: return "Login Timeout";
    case 449: return "Retry With";
    //case 451: return "Redirect";

    case 444: return "No Response";
    case 494: return "Request Header Too Large";
    case 495: return "SSL Certificate Error";
    case 496: return "SSL Certificate Required";
    case 497: return "HTTP Request Sent to HTTPS Port";
    //case 499: return "Client Closed Request";

    case 520: return "Web Server Returned an Unknown Error";
    case 521: return "Web Server Is Down";
    case 522: return "Connection Timed Out";
    case 523: return "Origin Is Unreachable";
    case 524: return "A Timeout Occurred";
    case 525: return "SSL Handshake Failed";
    case 526: return "Invalid SSL Certificate";
    case 527: return "Railgun Error";
    //case 530: return "(no text)";

    case 460: return "Client Closed Connection";
    case 463: return "Too Many IP Addresses";
    case 464: return "Incompatible Protocol";

    case 110: return "Response is Stale";
    case 111: return "Revalidation Failed";
    case 112: return "Disconnected Operation";
    case 113: return "Heuristic Expiration";
    case 199: return "Miscellaneous Warning";
    case 214: return "Transformation Applied";
    case 299: return "Miscellaneous Persistent Warning";

    default: return "(Unknown HTTP response)";
    }
}


// errnoMap
/++
    Reverse mapping of [core.stdc.errno.errno|errno] values to their string names.

    Automatically generated by introspecting [core.stdc.errno] with the code below.

    ---
    string[134] errnoMap;

    foreach (immutable symname; __traits(allMembers, core.stdc.errno))
    {
        static if (symname[0] == 'E')
        {
            immutable idx = __traits(getMember, core.stdc.errno, symname);

            if (errnoMap[idx].length)
            {
                writefln("// %s DUPLICATE %d", symname, idx);
            }
            else
            {
                errnoMap[idx] = symname;
            }
        }
    }

    writeln("static immutable string[134] errnoMap =\n[");

    foreach (immutable i, immutable e; errnoMap)
    {
        if (!e.length) continue;
        writefln(`    %-3d : "%s",`, i, e);
    }

    writeln("];");
    ---
 +/
version(Posix)
static immutable string[134] errnoMap =
[
    0   : "(unset)",
    1   : "EPERM",
    2   : "ENOENT",
    3   : "ESRCH",
    4   : "EINTR",
    5   : "EIO",
    6   : "ENXIO",
    7   : "E2BIG",
    8   : "ENOEXEC",
    9   : "EBADF",
    10  : "ECHILD",
    11  : "EAGAIN",  // duplicate EWOULDBLOCK
    12  : "ENOMEM",
    13  : "EACCES",
    14  : "EFAULT",
    15  : "ENOTBLK",
    16  : "EBUSY",
    17  : "EEXIST",
    18  : "EXDEV",
    19  : "ENODEV",
    20  : "ENOTDIR",
    21  : "EISDIR",
    22  : "EINVAL",
    23  : "ENFILE",
    24  : "EMFILE",
    25  : "ENOTTY",
    26  : "ETXTBSY",
    27  : "EFBIG",
    28  : "ENOSPC",
    29  : "ESPIPE",
    30  : "EROFS",
    31  : "EMLINK",
    32  : "EPIPE",
    33  : "EDOM",
    34  : "ERANGE",
    35  : "EDEADLK",  // duplicate EDEADLOCK
    36  : "ENAMETOOLONG",
    37  : "ENOLCK",
    38  : "ENOSYS",
    39  : "ENOTEMPTY",
    40  : "ELOOP",
    42  : "ENOMSG",
    43  : "EIDRM",
    44  : "ECHRNG",
    45  : "EL2NSYNC",
    46  : "EL3HLT",
    47  : "EL3RST",
    48  : "ELNRNG",
    49  : "EUNATCH",
    50  : "ENOCSI",
    51  : "EL2HLT",
    52  : "EBADE",
    53  : "EBADR",
    54  : "EXFULL",
    55  : "ENOANO",
    56  : "EBADRQC",
    57  : "EBADSLT",
    59  : "EBFONT",
    60  : "ENOSTR",
    61  : "ENODATA",
    62  : "ETIME",
    63  : "ENOSR",
    64  : "ENONET",
    65  : "ENOPKG",
    66  : "EREMOTE",
    67  : "ENOLINK",
    68  : "EADV",
    69  : "ESRMNT",
    70  : "ECOMM",
    71  : "EPROTO",
    72  : "EMULTIHOP",
    73  : "EDOTDOT",
    74  : "EBADMSG",
    75  : "EOVERFLOW",
    76  : "ENOTUNIQ",
    77  : "EBADFD",
    78  : "EREMCHG",
    79  : "ELIBACC",
    80  : "ELIBBAD",
    81  : "ELIBSCN",
    82  : "ELIBMAX",
    83  : "ELIBEXEC",
    84  : "EILSEQ",
    85  : "ERESTART",
    86  : "ESTRPIPE",
    87  : "EUSERS",
    88  : "ENOTSOCK",
    89  : "EDESTADDRREQ",
    90  : "EMSGSIZE",
    91  : "EPROTOTYPE",
    92  : "ENOPROTOOPT",
    93  : "EPROTONOSUPPORT",
    94  : "ESOCKTNOSUPPORT",
    95  : "EOPNOTSUPP",  // duplicate ENOTSUPP
    96  : "EPFNOSUPPORT",
    97  : "EAFNOSUPPORT",
    98  : "EADDRINUSE",
    99  : "EADDRNOTAVAIL",
    100 : "ENETDOWN",
    101 : "ENETUNREACH",
    102 : "ENETRESET",
    103 : "ECONNABORTED",
    104 : "ECONNRESET",
    105 : "ENOBUFS",
    106 : "EISCONN",
    107 : "ENOTCONN",
    108 : "ESHUTDOWN",
    109 : "ETOOMANYREFS",
    110 : "ETIMEDOUT",
    111 : "ECONNREFUSED",
    112 : "EHOSTDOWN",
    113 : "EHOSTUNREACH",
    114 : "EALREADY",
    115 : "EINPROGRESS",
    116 : "ESTALE",
    117 : "EUCLEAN",
    118 : "ENOTNAM",
    119 : "ENAVAIL",
    120 : "EISNAM",
    121 : "EREMOTEIO",
    122 : "EDQUOT",
    123 : "ENOMEDIUM",
    124 : "EMEDIUMTYPE",
    125 : "ECANCELED",
    126 : "ENOKEY",
    127 : "EKEYEXPIRED",
    128 : "EKEYREVOKED",
    129 : "EKEYREJECTED",
    130 : "EOWNERDEAD",
    131 : "ENOTRECOVERABLE",
    132 : "ERFKILL",
    133 : "EHWPOISON",
];
