/**
	Authentication and authorization framework based on fine-grained roles.

	Copyright: © 2016 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.web.auth;

// TODO: instead of AuthInfo.authenticate(Service, ...), use Service.authenticate(AuthInfo, ...) to avoid cyclic dependency
// TODO: Insert validity checks into isAuthenticated (@authorized attribute requires all methods to be attributed and no-@authorized means no methods may be attributed)

import vibe.http.common : HTTPStatusException;
import vibe.http.status : HTTPStatus;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
import vibe.internal.meta.uda : findFirstUDA;

static if (__VERSION__ <= 2067) import std.typetuple : AliasSeq = TypeTuple, staticIndexOf;
else import std.meta : AliasSeq, staticIndexOf;

///
unittest {
	import vibe.http.router : URLRouter;
	import vibe.web.web : registerWebInterface;

	@authorized!(ChatWebService.AuthInfo)
	static class ChatWebService {
		static struct AuthInfo {
			string userName;

			static AuthInfo authenticate(ChatWebService svc, scope HTTPServerRequest req, scope HTTPServerResponse res)
			{
				if (req.headers["AuthToken"] == "foobar")
					return AuthInfo(req.headers["AuthUser"]);
				throw new HTTPStatusException(HTTPStatus.unauthorized);
			}
			
			bool isAdmin() { return this.userName == "tom"; }
			bool isRoomMember(int chat_room) {
				if (chat_room == 0)
					return this.userName == "macy" || this.userName == "peter";
				else if (chat_room == 1)
					return this.userName == "macy";
				else
					return false;
			}
			bool isPremiumUser() { return this.userName == "peter"; }
		}

		@noAuth
		void getLoginPage()
		{
			// code that can be executed for any client
		}

		@anyAuth
		void getOverview()
		{
			// code that can be executed by any registered user
		}

		@auth(Role.admin)
		void getAdminSection()
		{
			// code that may only be executed by adminitrators
		}

		@auth(Role.admin | Role.roomMember)
		void getChatroomHistory(int chat_room)
		{
			// code that may execute for administrators or for chat room members
		}

		@auth(Role.roomMember & Role.premiumUser)
		void getPremiumInformation(int chat_room)
		{
			// code that may only execute for users that are members of a room and have a premium subscription
		}
	}

	void registerService(URLRouter router)
	{
		router.registerWebInterface(new ChatWebService);
	}
}


/**
	Enables authentication and authorization checks for an interface class.

	Web/REST interface classes that have authentication enabled are required
	to specify either the `@auth` or the `@noAuth` attribute for every public
	method.
*/
@property AuthorizedAttribute!T authorized(T)() { return AuthorizedAttribute!T.init; }

/** Enforces authentication and authorization.

	Params:
		roles = Role expression to control authorization. If no role
			set is given, any authenticated user is granted access.
*/
AuthAttribute!R auth(R)(R roles) { return AuthAttribute!R.init; }

/** Enforces only authentication.
*/
@property AuthAttribute!void anyAuth() { return AuthAttribute!void.init; }

/** Disables authentication checks.
*/
@property NoAuthAttribute noAuth() { return NoAuthAttribute.init; }

/// private
struct AuthorizedAttribute(T) { alias AuthInfo = T; }

/// private
struct AuthAttribute(R) { alias Roles = R; }

// private
struct NoAuthAttribute {}

/** Represents a required authorization role.

	Roles can be combined using logical or (`|` operator) or logical and (`&`
	operator). The role name is directly mapped to a method name of the
	authorization interface specified on the web interface class using the
	`@authorized` attribute.

	See_Also: `auth`
*/
struct Role {
	@disable this();

	static @property R!(Op.ident, name, void, void) opDispatch(string name)() { return R!(Op.ident, name, void, void).init; }
}

package auto handleAuthentication(alias fun, C)(C c, HTTPServerRequest req, HTTPServerResponse res)
{
	import std.traits : MemberFunctionsTuple;

	alias AI = AuthInfo!C;
	enum funname = __traits(identifier, fun);

	static if (!is(AI == void)) {
		alias AR = GetAuthAttribute!fun;
		static if (findFirstUDA!(NoAuthAttribute, fun).found) {
			static assert (is(AR == void), "Method "~funname~" specifies both, @noAuth and @auth(...)/@anyAuth attributes.");
			static assert(!hasParameterType!(fun, AI), "Method "~funname~" is attributed @noAuth, but also has an "~AI.stringof~" paramter.");
			// nothing to do
		} else {
			static assert(!is(AR == void), "Missing @auth(...)/@anyAuth attribute for method "~funname~".");
			return AI.authenticate(c, req, res);
		}
	} else {
		// make sure that there are no @auth/@noAuth annotations for non-authorizing classes
		foreach (mem; __traits(allMembers, C))
			foreach (fun; MemberFunctionsTuple!(C, mem)) {
				static if (__traits(getProtection, fun) == "public") {
					static assert (!findFirstUDA!(NoAuthAttribute, C).found,
						"@noAuth attribute on method "~funname~" is not allowed without annotating "~C.stringof~" with @authorized.");
					static assert (is(GetAuthAttribute!fun == void),
						"@auth(...)/@anyAuth attribute on method "~funname~" is not allowed without annotating "~C.stringof~" with @authorized.");
				}
			}
	}
}

package void handleAuthorization(C, alias fun, PARAMS...)(AuthInfo!C auth_info)
{
	import std.traits : MemberFunctionsTuple, ParameterIdentifierTuple;
	import vibe.internal.meta.typetuple : Group;

	alias AI = AuthInfo!C;
	alias ParamNames = Group!(ParameterIdentifierTuple!fun);

	static if (!is(AI == void)) {
		static if (!findFirstUDA!(NoAuthAttribute, fun).found) {
			alias AR = GetAuthAttribute!fun;
			static if (!is(AR.Roles == void))
				if (!evaluate!(__traits(identifier, fun), AR.Roles, AI, ParamNames, PARAMS)(auth_info))
					throw new HTTPStatusException(HTTPStatus.forbidden, "Not allowed to access this resource.");
			// successfully authorized, fall-through
		}
	}
}

package enum bool isAuthenticated(C, alias fun) = !is(AuthInfo!C == void) && !findFirstUDA!(NoAuthAttribute, fun).found;

package template AuthInfo(C)
{
	import std.traits : BaseTypeTuple, isInstanceOf;
	alias ATTS = AliasSeq!(__traits(getAttributes, C));
	alias BASES = BaseTypeTuple!C;

	template impl(size_t idx) {
		static if (idx < ATTS.length) {
			static if (is(typeof(ATTS[idx])) && isInstanceOf!(AuthorizedAttribute, typeof(ATTS[idx]))) {
				alias impl = typeof(ATTS[idx]).AuthInfo;
				static assert (is(typeof(impl.authenticate(C.init, HTTPServerRequest.init, HTTPServerResponse.init)) == impl),
					"@authorized!"~impl.stringof~" for "~C.stringof~" specifies a type that is missing a properly defined authenticate() static method.");
				static assert(is(impl!(idx+1) == void), "Class "~C.stringof~" defines multiple @authorized attributes.");
			} else alias impl = impl!(idx+1);
		} else alias impl = void;
	}

	template cimpl(size_t idx) {
		static if (idx < BASES.length) {
			alias AI = AuthInfo!(BASES[idx]);
			static if (is(AI == void)) alias cimpl = cimpl!(idx+1);
			else alias cimpl = AI;
		} else alias cimpl = void;
	}

	static if (!is(impl!0 == void)) alias AuthInfo = impl!0;
	else alias AuthInfo = cimpl!0;
}

unittest {
	@authorized!(I.A)
	static class I {
		static struct A {}
	}
	static assert (!is(AuthInfo!I)); // missing authenticate method

	@authorized!(J.A)
	static class J {
		static struct A {
			static A authenticate(J, HTTPServerRequest, HTTPServerResponse) { return A.init; }
		}
	}
	static assert (is(AuthInfo!J == J.A));

	static class K {}
	static assert (is(AuthInfo!K == void));

	static class L : J {}
	static assert (is(AuthInfo!L == J.A));

	@authorized!(M.A)
	interface M {
		static struct A {
			static A authenticate(M, HTTPServerRequest, HTTPServerResponse) { return A.init; }
		}
	}
	static class N : M {}
	static assert (is(AuthInfo!N == M.A));
}

private template GetAuthAttribute(alias fun)
{
	import std.traits : isInstanceOf;
	alias ATTS = AliasSeq!(__traits(getAttributes, fun));

	template impl(size_t idx) {
		static if (idx < ATTS.length) {
			static if (is(typeof(ATTS[idx])) && isInstanceOf!(AuthAttribute, typeof(ATTS[idx]))) {
				alias impl = typeof(ATTS[idx]);
				static assert(is(impl!(idx+1) == void), "Method "~__traits(identifier, fun)~" may only specify one @auth attribute.");
			} else alias impl = impl!(idx+1);
		} else alias impl = void;
	}
	alias GetAuthAttribute = impl!0;
}

unittest {
	@auth(Role.a) void c();
	static assert(is(GetAuthAttribute!c.Roles == typeof(Role.a)));

	void d();
	static assert(is(GetAuthAttribute!d == void));

	@anyAuth void a();
	static assert(is(GetAuthAttribute!a.Roles == void));

	@anyAuth @anyAuth void b();
	static assert(!is(GetAuthAttribute!b));

}

private enum Op { none, and, or, ident }

private struct R(Op op_, string ident_, Left_, Right_) {
	alias op = op_;
	enum ident = ident_;
	alias Left = Left_;
	alias Right = Right_;

	R!(Op.or, null, R, O) opBinary(string op : "|", O)(O other) { return R!(Op.or, null, R, O).init; }
	R!(Op.and, null, R, O) opBinary(string op : "&", O)(O other) { return R!(Op.and, null, R, O).init; }
}

private bool evaluate(string methodname, R, A, alias ParamNames, PARAMS...)(ref A a)
{
	import std.ascii : toUpper;
	import std.traits : ParameterTypeTuple, ParameterIdentifierTuple;

	static if (R.op == Op.ident) {
		enum fname = "is" ~ toUpper(R.ident[0]) ~ R.ident[1 .. $];
		alias func = AliasSeq!(__traits(getMember, a, fname))[0];
		alias fpNames = ParameterIdentifierTuple!func;
		alias FPTypes = ParameterTypeTuple!func;
		FPTypes params;
		foreach (i, P; FPTypes) {
			enum name = fpNames[i];
			enum j = staticIndexOf!(name, ParamNames.expand);
			static assert(j >= 0, "Missing parameter "~name~" to evaluate @auth attribute for method "~methodname~".");
			static assert (is(typeof(PARAMS[j]) == P),
				"Parameter "~name~" of "~methodname~" is expected to have type "~P.stringof~" to match @auth attribute.");
			params[i] = PARAMS[j];
		}
		return __traits(getMember, a, fname)(params);
	}
	else static if (R.op == Op.and) return evaluate!(methodname, R.Left, A, ParamNames, PARAMS)(a) && evaluate!(methodname, R.Right, A, ParamNames, PARAMS)(a);
	else static if (R.op == Op.or) return evaluate!(methodname, R.Left, A, ParamNames, PARAMS)(a) || evaluate!(methodname, R.Right, A, ParamNames, PARAMS)(a);
	else return true;
}

unittest {
	import vibe.internal.meta.typetuple : Group;

	static struct AuthInfo {
		this(string u) { this.username = u; }
		string username;

		bool isAdmin() { return this.username == "peter"; }
		bool isMember(int room) { return this.username == "tom"; }
	}

	auto peter = AuthInfo("peter");
	auto tom = AuthInfo("tom");

	{
		int room;

		alias defargs = AliasSeq!(AuthInfo, Group!("room"), room);

		auto ra = Role.admin;
		assert(evaluate!("x", typeof(ra), defargs)(peter) == true);
		assert(evaluate!("x", typeof(ra), defargs)(tom) == false);

		auto rb = Role.member;
		assert(evaluate!("x", typeof(rb), defargs)(peter) == false);
		assert(evaluate!("x", typeof(rb), defargs)(tom) == true);

		auto rc = Role.admin & Role.member;
		assert(evaluate!("x", typeof(rc), defargs)(peter) == false);
		assert(evaluate!("x", typeof(rc), defargs)(tom) == false);

		auto rd = Role.admin | Role.member;
		assert(evaluate!("x", typeof(rd), defargs)(peter) == true);
		assert(evaluate!("x", typeof(rd), defargs)(tom) == true);

		static assert(__traits(compiles, evaluate!("x", typeof(ra), AuthInfo, Group!())(peter)));
		static assert(!__traits(compiles, evaluate!("x", typeof(rb), AuthInfo, Group!())(peter)));
	}

	{
		float room;
		static assert(!__traits(compiles, evaluate!("x", typeof(rb), AuthInfo, Group!("room"), room)(peter)));
	}

	{
		int foo;
		static assert(!__traits(compiles, evaluate!("x", typeof(rb), AuthInfo, Group!("foo"), foo)(peter)));
	}
}
