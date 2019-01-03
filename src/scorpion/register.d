﻿module scorpion.register;

import std.conv : to;
import std.exception : enforce;
import std.experimental.logger : info;
import std.regex : Regex;
import std.string : split, join;
import std.traits : hasUDA, getUDAs, isFunction, Parameters, ParameterIdentifierTuple;

import lighttp.router : Router, routeInfo;
import lighttp.util : StatusCodes, ServerRequest, ServerResponse;

import scorpion.component : Component, Init;
import scorpion.config : Config, ValueImpl, Configuration, LanguageConfiguration, ProfilesConfiguration;
import scorpion.controller : Controller, Route, Get, Post, Put, Delete, Path, Param, Body;
import scorpion.entity : Entity, ExtendEntity;
import scorpion.lang : LanguageManager;
import scorpion.model : Model;
import scorpion.profile : Profile;
import scorpion.service : Service, DatabaseRepository;
import scorpion.session : Session;
import scorpion.validation : Validation, validateParam, validateBody;

import shark : Database;

private template Alias(alias T) {

	alias T Alias;

}

private LanguageManager languageManager;

private ProfilesConfiguration[] profilesConfigurations;

private EntityInfo[] entities;

private ComponentInfo[] components;

private ServiceInfo[] services;

private ControllerInfo[] controllers;

private class Info {
	
	string[] profiles;

	this(string[] profiles) {
		this.profiles = profiles;
	}

}

private interface EntityInfo {

	void init(Config config, Database database);

}

private class EntityInfoImpl(T) : Info, EntityInfo {

	this(string[] profiles) {
		super(profiles);
	}

	override void init(Config config, Database database) {
		if(profiles.length == 0 || config.hasProfile(profiles)) {
			enforce!Exception(database !is null, "A database connection is required");
			database.init!T();
		}
	}

}

private interface ComponentInfo {

	Object instance();

	Object newInstance(Database);

}

private class ComponentInfoImpl(T) : ComponentInfo {

	private T cached;

	static this() {
		cached = new T();
	}

	override Object instance() {
		return cached;
	}

	override Object newInstance(Database database) {
		T ret = new T();
		initComponent(ret, database);
		return ret;
	}

}

private interface ServiceInfo {

	Object instance(Database);

}

private class ServiceInfoImpl(T) : ServiceInfo {

	private T cached;

	override Object instance(Database database) {
		if(cached is null) cached = new T(database);
		return cached;
	}

}

private interface ControllerInfo {

	void init(Router router, Config config, Database);

}

private class ControllerInfoImpl(T) : Info, ControllerInfo {

	this(string[] profiles) {
		super(profiles);
	}

	override void init(Router router, Config config, Database database) {
		if(profiles.length == 0 || config.hasProfile(profiles)) {
			T controller = new T();
			static if(!__traits(compiles, getUDAs!(T, Controller)[0]())) auto controllerPath = getUDAs!(T, Controller)[0].path;
			foreach(immutable member ; __traits(allMembers, T)) {
				static if(__traits(getProtection, __traits(getMember, T, member)) == "public") {
					immutable full = "controller." ~ member;
					static if(isFunction!(__traits(getMember, T, member))) {
						foreach(immutable uda ; __traits(getAttributes, __traits(getMember, T, member))) {
							static if(is(typeof(uda) == Route) || is(typeof(uda()) == Route)) {
								static if(is(typeof(controllerPath))) auto path = controllerPath ~ uda.path;
								else auto path = uda.path;
								alias F = Alias!(__traits(getMember, T, member));
								auto fun = mixin(generateFunction!F(member));
								info("Routing ", uda.method, " /", path.join("/"), " to ", T.stringof, ".", member);
								router.add(routeInfo(uda.method, path.join(`\/`)), fun);
							}
						}
					} else {
						static if(hasUDA!(__traits(getMember, T, member), Init)) {
							initComponent(mixin(full), database);
						}
						static if(hasUDA!(__traits(getMember, T, member), ValueImpl)) {
							immutable value = getUDAs!(__traits(getMember, T, member), ValueImpl)[0];
							mixin(full) = config.get!(typeof(value.defaultValue))(value.key, value.defaultValue);
						}
					}
				}
			}
		}
	}

	private static string generateFunction(alias M)(string member) {
		string[] ret = ["ServerRequest request", "ServerResponse response"];
		string body1 = "response.status=StatusCodes.ok;Validation validation=new Validation();";
		string body2;
		string[Parameters!M.length] call;
		foreach(i, param; Parameters!M) {
			static if(is(param == ServerRequest)) call[i] = "request";
			else static if(is(param == ServerResponse)) call[i] = "response";
			else static if(is(param == Model)) {
				body2 ~= "Model model=new Model(request,languageManager);";
				call[i] = "model";
			} else static if(is(param == Session)) {
				body2 ~= "Session session=Session.get(request);";
				call[i] = "session";
			} else static if(is(param == Validation)) {
				call[i] = "validation";
			} else static if(is(typeof(M) Params == __parameters)) {
				immutable p = "Parameters!F[" ~ i.to!string ~ "] " ~ member ~ i.to!string;
				call[i] = member ~ i.to!string;
				foreach(attr ; __traits(getAttributes, Params[i..i+1])) {
					static if(is(attr == Path)) {
						ret ~= p;
					} else static if(is(attr == Param) || is(typeof(attr) == Param)) {
						static if(is(attr == Param)) enum name = ParameterIdentifierTuple!M[i];
						else enum name = attr.param;
						body1 ~= p ~ "=validateParam!(Parameters!F[" ~ i.to!string ~ "])(\"" ~ name ~ "\",request,response);";
					} else static if(is(attr == Body)) {
						body1 ~= p ~ "=validateBody!(Parameters!F[" ~ i.to!string ~ "])(request,response,validation);";
					}
				}
			}
		}
		return "delegate(" ~ ret.join(",") ~ "){" ~ body1 ~ body2 ~ "controller." ~ member ~ "(" ~ join(cast(string[])call, ",") ~ ");validation.apply(response);}";
	}

}

private void initComponent(T)(ref T value, Database database) {
	foreach(component ; components) {
		if(cast(T)component.instance) {
			value = cast(T)component.newInstance(database);
			return;
		}
	}
	foreach(service ; services) {
		if(cast(T)service.instance(database)) {
			value = cast(T)service.instance(database);
			return;
		}
	}
}

void init(Router router, Config config, Database database) {
	foreach(profilesConfiguration ; profilesConfigurations) {
		config.addProfiles(profilesConfiguration.defaultProfiles());
	}
	info("Active profiles: ", config.profiles.join(", "));
	foreach(entityInfo ; entities) {
		entityInfo.init(config, database);
	}
	foreach(controllerInfo ; controllers) {
		controllerInfo.init(router, config, database);
	}
}

void registerModule(string module_)() {
	mixin("static import " ~ module_ ~ ";");
	foreach(immutable member ; __traits(allMembers, mixin(module_))) {
		static if(__traits(getProtection, __traits(getMember, mixin(module_), member)) == "public") {
			immutable full = module_ ~ "." ~ member;
			static if(hasUDA!(mixin(full), Configuration)) {
				mixin("alias T = " ~ full ~ ";");
				T configuration = new T();
				static if(is(T : LanguageConfiguration)) {
					foreach(lang, data; configuration.loadLanguages()) {
						languageManager.add(lang, data);
					}
				}
				static if(is(T : ProfilesConfiguration)) {
					profilesConfigurations ~= configuration;
				}
			}
			static if(hasUDA!(mixin(full), Entity)) {
				entities ~= new EntityInfoImpl!(ExtendEntity!(mixin(full), getUDAs!(mixin(full), Entity)[0].name))(Profile.get(getUDAs!(mixin(full), Profile)));
			}
			static if(hasUDA!(mixin(full), Component)) {
				components ~= new ComponentInfoImpl!(mixin(full))();
			}
			static if(hasUDA!(mixin(full), Service)) {
				services ~= new ServiceInfoImpl!(DatabaseRepository!(mixin(full)))();
			}
			static if(hasUDA!(mixin(full), Controller)) {
				controllers ~= new ControllerInfoImpl!(mixin(full))(Profile.get(getUDAs!(mixin(full), Profile)));
			}
		}
	}
}