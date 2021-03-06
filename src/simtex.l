%{
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>

#include <getopt.h>
#include <libgen.h>

#include <iostream>
#include <string>
#include <map>
#include <set>
#include <vector>
#include <sstream>

#ifdef DEBUG
// use extended ascii to demarcate output
// to do this, use the utf-8 encoding of the extended ascii
// to do *this*, first find the unicode of the extended ascii
// use the "OEM Code Page 437 Unicode Mapping" on http://www.on-time.com/rtos-32-docs/rtfiles-32/reference-manual/code-page.htm
// then use http://www.endmemo.com/unicode/unicodeconverter.php and enter the escaped unicode and calculte, then grab the 
// utf-8 code and embed it.
// can we friggin automate this please? ie. exASCII(number) -> utf-8 string?
#define STARTBLOCK "\xc2\xab"
#define STOPBLOCK  "\xc2\xbb"
#define LOG(ARG...)		std::clog<<STARTBLOCK<<ARG<<STOPBLOCK
#define TRACE(ARG...)	std::cerr<<"DBG: "<<ARG<<std::endl;
#else
#define LOG(...)
#define TRACE(ARG...)
#endif

#define OUTPUT(ARG...)	LOG(ARG); current().output<<ARG

/* Action is used by a pushed context on wakeup to remember what it was doing
when it was suspended.
Filename is |'ed with one of Include, Import or Inherit to indicate that the
context was resolving a filename for a specific purpose.
*/
enum Action
{
	Include 	= 1 << 0,
	Import		= 1 << 1,
	Inherit		= 1 << 2,
	Filename	= 1 << 3,
	DefineKey	= 1 << 4,
	DefineValue = 1 << 5,
	AppendValue = 1 << 6,
	Ifdef		= 1 << 7,
	Condition	= 1 << 8,
	ResolveKey	= 1 << 9,
};

struct Value
{
	std::string value;
	
	bool global;
	bool final;
	
	Value(const std::string& v = "", bool g = true, bool f = false)
	: value(v)
	, global(g)
	, final(f)
	{}
};

std::ostream& operator<<(std::ostream& stream, const Value& value)
{
	return stream<<(value.global?"[G]":"")<<(value.final?"[F]":"")<<value.value;
}

/* Context is used to represent the current parsing state of a specific buffer.
The buffers are organised as a stack, with the top Context being the active one.
All buffers below the current stack are suspended. When the current context
is popped from the stack, the next Context wakes up, and resumes its parsing.
*/
struct Context
{
	std::string name; // store the filename
	std::string path; // store tha pathname
	// defkey is used to remember the current $def key
	std::string defkey;
	std::string defval;
	// env represents all the key -> value mappings
	std::map<std::string, ::Value> env;
	// buffer represents the input buffer
	YY_BUFFER_STATE buffer;
	// output is the parsed output of the context
	std::stringstream output;
	// action stores the Action of the current (suspended) context
	int action;
	// if base is true, the Context represents an inherited context
	bool base;
	// if the context is marked as inherited, the derived set
	// stores all env keys which have been specialised by derived contexts,
	// and are therefore immutable by the inherited context
	// if file is not null, the buffer is being read from the file
	FILE* file;
	
	Context(const std::string& n, const std::string& p, YY_BUFFER_STATE b, FILE* f = NULL, int a = 0)
	: name(n)
	, path(p)
	, buffer(b)
	, file(f)
	, action(a)
	, base(a == Inherit)
	{}
	
	~Context()
	{
		if (file) fclose(file);
		yy_delete_buffer(buffer);
	}
};

std::vector<std::string> path;
std::vector<Context*> stack;

struct File
{
	std::string filename;
	int action;
	
	File(const std::string& fn, int a)
	: filename(fn)
	, action(a)
	{}
};
std::vector<File> files;

Context& current()
{
	return *stack.back();
}

void printstack()
{
#ifdef DEBUG
	TRACE("stack is");
	for (std::vector<Context*>::reverse_iterator i = stack.rbegin(); i != stack.rend(); ++i)
	{
		std::cerr<<"\t"<<(void*)(*i)<<std::endl;
	}
#endif
}

/* These functions either suspend (push/insert) or wakeup (pop) the contexts in the stack */
int popbuffer();
void pushstring(const std::string& string, int action);
void pushfile(std::string filename, int action);
void insertfile(std::string filename, int action);

/* This copies the env keyvalues from a to b.
If b is marked as an inherited (ie. base) context, the keys are added to its derived
member. The derived member is used in turn to detect whether a key has been specified
by a derived context, so that overwriting by the base context can be prevented.
*/
void copy(Context* a, Context* b)
{
	for (std::map<std::string, Value>::iterator i = a->env.begin(); i != a->env.end(); ++i)
	{
		if (i->second.global)
		{
			TRACE("copying key ["<<i->first<<"] = '"<<i->second<<"'");
			b->env[i->first] = i->second;
			if (b->base)
				b->env[i->first].final = true;
		}
		else
		{
			TRACE("ignoring local key ["<<i->first<<"]");
		}
	}
	if (b->base)
		TRACE("marking all as derived");
}

bool defined(const std::string& key)
{
	// start at the back, and look for the key
	for (std::vector<Context*>::reverse_iterator s = stack.rbegin(); s != stack.rend(); ++s)
	{
		std::map<std::string, ::Value>::iterator i = (*s)->env.find(key);
		if (i != (*s)->env.end()) return true;
	}
	return false;
}

/* This function returns the value of a requested key.
The stack is traversed from top to bottom, and if no key is found, value() returns either
the empty string, the key name verbatim or throws an error, depending on the configuration.
TODO: implement this!
*/
std::string resolve(const std::string& key)
{
	// start at the back, and look for the key[1:]
	// TODO: fix this so that the caller takes care of cleanup up the name!
	for (std::vector<Context*>::reverse_iterator s = stack.rbegin(); s != stack.rend(); ++s)
	{
		std::map<std::string, ::Value>::iterator i = (*s)->env.find(key);
		if (i != (*s)->env.end()) return i->second.value;
	}
	return "";
}
/* Store will overwrite the key with name current->defkey using the current defval value.
This is prevented when the key is in the derived set, however.
*/
void store()
{
	std::map<std::string, Value>::iterator i = current().env.find(current().defkey);
	if (i != current().env.end() && i->second.final)
	{
		// the item is in the list AND marked final
		TRACE("ignoring derived keyvalue");
	}
	else
	{
		// the item is not in the list, or if it is, it is marked as not final
		TRACE("storing ["<<current().defkey<<"] = '"<<current().defval<<"'");
		current().env[current().defkey] = current().defval;
	}
}

/* These are wrapped functions for yy_xxx_state, to facilitate debugging */
void setstate(int s);
void pushstate(int s);
void popstate();
int  getstate();
void printstate();

%}
%x DEFKEY
%x DEFVAL
%x INCLUDE
%x IMPORT
%x INHERIT
%x IFDEF
%x ENDIF
%x COMMENT
%x MULTICOMMENT
%option stack
%%
<<EOF>>			{					// match end of file
					TRACE("<<EOF>>");
					if (popbuffer()) yyterminate();
		        }///////////////////////////////////////
\$\$			{					// match "$$"
					TRACE("replacing escaped $");
					OUTPUT('$');
				}///////////////////////////////////////
^\\\$/[^$]		{					// match \$ at start of line, unless followed by another $
					setstate(COMMENT);
				}
\\\$/[^$]		{					// match \$ unless followed by another $
					OUTPUT('\n'); // add a newline, since the original line is not empty
					setstate(COMMENT);
				}
<COMMENT>.*\n	{					// eat the rest of the line
					setstate(INITIAL);
				}
\/\$.*\n		{
					setstate(MULTICOMMENT);
				}
<MULTICOMMENT>\$\/ {
					setstate(INITIAL);
				}
<MULTICOMMENT>.|\n {
					// ignore multiline comment
				}
\$\([^\)]*\)	{					// match "$(...)"
					std::string text = std::string(yytext);
					text = text.substr(2, text.length()-3); // strip the $( and )
					TRACE("$(key) reference ["<<text<<"]");
					pushstring(text, ResolveKey);
					//OUTPUT(value(text));
				}
\$[a-zA-Z_]+[a-zA-Z0-9_]*	{		// match "$<KEYNAME>"
					std::string text = std::string(yytext);
					text = text.substr(1); // strip the $
					TRACE("$key reference ["<<text<<"]");
					OUTPUT(resolve(text));
				}///////////////////////////////////////
\$def[ \t]+		{					// match "$def", eating up any trailing whitespace
					TRACE("found $def");
					pushstate(DEFKEY);
				}
<DEFKEY>[^ \t]*[ \t]+ {				// match a run of non-whitespace, followed by whitespace - ie. a single word
					std::string text = std::string(yytext);
					size_t b = text.find_last_not_of(" \t");
					text[b+1] = 0; // artificially chop the whitespace
					TRACE("def key text ["<<text<<"]");
					setstate(DEFVAL);
					pushstring(text, DefineKey);
				}
<DEFVAL>.*\\\n	{
					// append a value to the stored defval
					// keep going, there is a trailing backslash
					// retain two newlines: one will be trimmed!
					std::string text = yytext;
					text[strlen(yytext)-2] = '\n';
					TRACE("def value (cont.) ["<<text<<"]");
					pushstring(text, AppendValue);
				}
<DEFVAL>.*		{					// match the rest of the line (eat the newline)
					std::string text = std::string(yytext, strlen(yytext));
					TRACE("def value text ["<<text<<"]");
					popstate(); // ex-DEFVAL
					pushstring(text, DefineValue);
				}///////////////////////////////////////
\$include[ \t]+	{					// match "$include", eating up any trailing whitespace
					TRACE("found $include");
					pushstate(INCLUDE);
				}
<INCLUDE>.*\n	{					// match the rest of the line (eat the newline)
					std::string text = std::string(yytext, strlen(yytext)-1);
					TRACE("include text ["<<text<<"]");
					popstate(); // ex-INCLUDE
					pushstring(text, Include | Filename);
				}///////////////////////////////////////
\$import[ \t]+	{					// match "$import", eating up any trailing whitespace
					TRACE("found $import");
					pushstate(IMPORT);
				}
<IMPORT>.*\n	{					// match the rest of the line (eat the newline)
					std::string text = std::string(yytext, strlen(yytext)-1);
					TRACE("import text ["<<text<<"]");
					popstate(); // ex-IMPORT
					pushstring(text, Import | Filename);
				}///////////////////////////////////////
\$inherit[ \t]+	{					// match "$inherit", eating up any trailing whitespace
					TRACE("found $inherit");
					pushstate(INHERIT);
				}
<INHERIT>.*\n	{					// match the rest of the line (eat the newline)
					std::string text = std::string(yytext, strlen(yytext)-1);
					TRACE("inherit text ["<<text<<"]");
					popstate(); // ex-INHERIT
					pushstring(text, Inherit | Filename);
				}///////////////////////////////////////
\$ifdef[ \t]+	{					// match "$ifdef", eating up any trailing whitespace
					TRACE("found $ifdef");
					pushstate(IFDEF);
				}
<IFDEF>.*\n		{					// match the rest of the line (eat the newline)
					std::string text = std::string(yytext, strlen(yytext)-1);
					TRACE("ifdef text ["<<text<<"]");
					popstate(); // ex-IFDEF
					pushstring(text, Ifdef | Condition);
				}
<ENDIF>.|\n		{					// matches any character including newline in endif mode
					// discard active endif block
				}
<ENDIF>$endif[ \t]*\n {				// matches active $endif line (eat the newline)
					TRACE("found active endif");
					setstate(INITIAL);
				}
$endif[ \t]*\n	{		 			// matches $endif line (eat the newline)
					TRACE("found inactive endif");
				}///////////////////////////////////////
.|\n			{					// match any leftover character (including newline)
					OUTPUT(yytext); 
				}
%%

void setstate(int s)
{
	BEGIN(s);
}
void pushstate(int s)
{
	yy_push_state(s);
}
void popstate()
{
	yy_pop_state();
}
int getstate()
{
	return yy_top_state();
}

#define CASESTATE(X) case X: std::cerr<<"\t"#X<<std::endl; break
void printstate()
{
#ifdef DEBUG
	TRACE("state is");
	int s = getstate();
	switch (s)
	{
		CASESTATE(DEFKEY);
		CASESTATE(DEFVAL);
		CASESTATE(INCLUDE);
		CASESTATE(IMPORT);
		CASESTATE(INHERIT);
	}
#endif
}

FILE* checkfile(const std::string& fullname, std::string* nameout, std::string* pathout)
{
	TRACE("attempting to open file ["<<fullname<<"]");
	FILE* f = NULL;
	char* fn = strdup(fullname.c_str());
	struct stat buf;
	if (stat(fn, &buf) == 0)
	{
		if (S_ISREG(buf.st_mode))
		{
			f = fopen(fn, "r");
			if (f)
			{
				size_t s = fullname.find_last_of("/");
				*pathout = fullname.substr(0, s);
				*nameout = fullname.substr(s+1, fullname.length()-s-1);
				TRACE("success: filename ["<<*nameout<<"] pathname ["<<*pathout<<"]");
				goto done;
			}
			else
			{
				TRACE("could not open ["<<fullname<<"]");
			}
		}
		else
		{
			TRACE("not a file ["<<fullname<<"]");
		}
	}
	else
	{
		TRACE("could not stat ["<<fullname<<"]");
	}
done:
	free(fn);
	return f;
}

/* this looks for the filename in the search path, as well as in the accumulated
context path. It returns an open FILE descriptor for the first accessible file it finds,
or NULL if none could be found.
*/
FILE* resolvefile(const std::string& filename, std::string* nameout, std::string* pathout)
{
	FILE* f = NULL;
	// look through the path
	for (std::vector<std::string>::iterator p = path.begin(); p != path.end(); ++p)
	{
		std::string fullname = *p + '/' + filename;
		f = checkfile(fullname, nameout, pathout);
		if (f)
			goto done;
	}
	// look through the contexts
	for (std::vector<Context*>::iterator s = stack.begin(); s != stack.end(); ++s)
	{
		std::string fullname = (*s)->path + '/' + filename;
		f = checkfile(fullname, nameout, pathout);
		if (f)
			goto done;
	}
done:
	return f;
}

bool nextfile()
{
	// check whether the filelist is empty
	if (files.empty()) return false;
	File file = files.back();
	files.pop_back();
	std::string pathname;
	std::string filename;
	FILE* f = (file.filename == "-") ? stdin : resolvefile(file.filename, &filename, &pathname);
	if (!f)
	{
		std::cerr<<"ERR: Failed to open file ["<<filename<<"]"<<std::endl;
		exit(1);
	}
	// TODO: check the File::action to decide HOW to include/import the file
	// possibly this could be used to specify an inherit on the commandline as well.
	// The problem with import is that we need to carry stuff over from one context to the next?
	stack.push_back(new Context(filename, pathname, yy_create_buffer(f, YY_BUF_SIZE), f));
	pushstate(INITIAL);
	return true;
}

int popbuffer()
{
	Context* context = stack.back();
	std::string value = context->output.str();
	// chop the leading and trailing newline, if any
	size_t s0 = 0;
	size_t s1 = value.length();
	if (value[0] == '\n') { s0 += 1; s1-= 1; }
	if (value[value.length()-1] == '\n') s1 -= 1;
	value = value.substr(s0, s1);
	//value = value.substr(0, value.find_last_of("\n"));
	TRACE("popping context ["<<context->name<<"]");
	stack.pop_back();
	if (stack.empty())
	{
		TRACE("output:::::::::");
		std::cout<<value<<std::endl; // TODO: configure the trailing newline (like -n?)
		TRACE("stack is empty");
		if (!nextfile())
		{
			delete context;
			return 1;
		}
	}
	TRACE("current context is now ["<<current().name<<"]");
	//TRACE("current output is ["<<current().output.str()<<"]");
	yy_switch_to_buffer(current().buffer);
	popstate();
	copy(context, stack.back());
	switch (current().action)
	{
		case DefineKey:
			TRACE("def key ["<<value<<"]");
			current().defkey = value;
			break;
		case AppendValue:
			TRACE("def value ["<<value<<"]");
			current().defval += value;
			break;
		case DefineValue:
			TRACE("def value ["<<value<<"]");
			current().defval += value;
			store();
			current().defval = "";
			break;
		case Include | Filename:
			TRACE("include filename ["<<value<<"]");
			pushfile(value, Include);
			break;
		case Import | Filename:
			TRACE("import filename ["<<value<<"]");
			pushfile(value, Import);
			break;
		case Inherit | Filename:
			TRACE("inherit filename ["<<value<<"]");
			insertfile(value, Inherit);
			break;
		case Import:
			TRACE("discarding output ["<<value<<"]");
			break;
		case Inherit:
			TRACE("adding $__OUTPUT__ output ["<<value<<"]");
			// note, we chop the trailing newline, so that we don't have any unwanted spacing
			current().env["__OUTPUT__"] = value; //value.substr(0, value.length()-1);
			break;
		case Include:
			TRACE("including output ["<<value<<"]");
			OUTPUT(value);
			break;
		case Ifdef | Condition:
			TRACE("ifdef text ["<<value<<"]");
			if (defined(value))
			{
				TRACE("key ["<<value<<"] is defined, setting INITIAL");
				setstate(INITIAL);
			}
			else
			{
				TRACE("key ["<<value<<"] is undefined, setting ENDIF");
				setstate(ENDIF);
			}
			break;
		case ResolveKey:
			TRACE("resolving key ["<<value<<"]");
			OUTPUT(resolve(value));
			break;
		default:
			TRACE("discarding output ["<<value<<"]");
			break;
	}
	delete context;
	/*
	printstack();
	printstate();
	TRACE("current buffer is "<<YY_CURRENT_BUFFER);
	*/
	return 0;
}

void pushstring(const std::string& string, int action)
{
	TRACE("pushing string buffer");
	current().buffer = YY_CURRENT_BUFFER;
	current().action = action;
	// add a newline, to make sure that all commands terminate
	stack.push_back(new Context("String", "", yy_scan_string((string + "\n").c_str())));
	//
	// this is already done by yy_scan_string: yy_switch_to_buffer(current().buffer);
	pushstate(INITIAL);
	/*
	printstack();
	printstate();
	TRACE("current buffer is "<<YY_CURRENT_BUFFER);
	*/
}
void pushfile(std::string filename, int action)
{
	TRACE("pushing file buffer");
	std::string pathname;
	FILE* f = resolvefile(filename, &filename, &pathname);
	if (!f)
	{
    	std::cerr<<"ERR: Failed to open included file ["<<filename<<"]"<<std::endl;
    	exit(1);
    }
    current().buffer = YY_CURRENT_BUFFER; // back up the current buffer
    current().action = action; // remember the action
    stack.push_back(new Context(filename, pathname, yy_create_buffer(f, YY_BUF_SIZE), f));
    //
    yy_switch_to_buffer(current().buffer);
	pushstate(INITIAL);
    /*
	printstack();
	printstate();
	TRACE("current buffer is "<<YY_CURRENT_BUFFER);
	*/
}
void insertfile(std::string filename, int action)
{
	TRACE("inserting file buffer");
	// insert the requested buffer *behind* the current one
	std::string pathname;
	FILE* f = resolvefile(filename, &filename, &pathname);
    if (!f)
    {
    	std::cerr<<"ERR: Failed to open included file ["<<filename<<"]"<<std::endl;
    	exit(1);
    }
    std::vector<Context*>::iterator i = stack.end() - 1;
	stack.insert(i, new Context(filename, pathname, yy_create_buffer(f, YY_BUF_SIZE), f, action));
	//
    yy_switch_to_buffer(current().buffer);
	pushstate(INITIAL);
	/*
	printstack();
	printstate();
	TRACE("current buffer is "<<YY_CURRENT_BUFFER);
	*/
}

void addpath(const std::string& base, const std::string& rel)
{
	char* p = 0;
	if (rel.length() > 0 && rel[0] == '/')
	{
		// path is an absolute path, so resolve it 
		p = realpath(rel.c_str(), NULL);
	}
	else
	{
		// path is not absolute, so append it to base and resolve it
		p = realpath((base + '/' + rel).c_str(), NULL);
	}
	if (p)
		path.push_back(std::string(p));
	free(p);
}

void usage(const char* self, int ret)
{
	std::cout<<
"Usage: "<<self<<" [FILES...]\n"
"where [FILES...] is the list of files to process"
	<<std::endl;
	exit(ret);
}

int main(int argc, char** argv)
{
#ifdef DEBUG
	std::cout.setf(std::ios::unitbuf);
	std::cerr.setf(std::ios::unitbuf);
#endif

	char* cwd = get_current_dir_name();
	path.push_back(std::string(cwd));
	
	// TODO: we need to use this setup context as the lone root of the context stack.
	// this will allow us to properly suck in the environments from commandline included
	// files. This will need modification of popbuffer, which will figure out that
	// we are back to the root, and so need to import/include/inherit the next file
	// (using nextfile(), or a modification).
	Context setup("SETUP", "", 0);
	optind = 0;
	int c = 0;
	while ((c = getopt (argc, argv, "-hD:I:i:")) != -1)
	{
		switch (c)
		{
			case 'h':
				usage(argv[0], 0);
				break;
			case 'D':
				// add the key to the setup context:
				setup.env[optarg].value = "";
				break;
			case 'I':
				// add a path to the search path
				addpath(cwd, optarg);
				break;
			case 'i':
				// add the file to be imported
				files.push_back(File(optarg, Import));
				break;
			case '\1':
				// add the file to be included
				files.push_back(File(optarg, Include));
				break;
			// TODO: add future options
			/* these could include:
			-d			: add comments for debugging
			-D CMNT		: use CMNT string before comments (default is "#")
			-r			: relaxed mode: ignore missing files
			-s			: strict mode: abort if a key is used but not defined
			-o OUTPUT	: output to the specified file (instead of stdout)
			-b BASE		: use BASE as an inherited file
			*/
			default:
				usage(argv[0], -1);
				break;
		}
	}
	free(cwd);
	
#ifdef DEBUG
	TRACE("path:");
	for (std::vector<std::string>::iterator i = path.begin(); i != path.end(); ++i)
	{
		std::cerr<<"\t"<<*i<<std::endl;
	}
#endif
	
	if (files.empty())
	{
		// if no filelist was specified, use stdin. This is already set up for us by flex
		TRACE("no filelist, using stdin");
		files.push_back(File("-", Include));
	}
	nextfile();
	copy(&setup, &current());
	yy_switch_to_buffer(current().buffer);
	
    TRACE("initting with buffer "<<current().buffer);
	TRACE("stack size: "<<stack.size());
	printstack();
	TRACE("current buffer is "<<YY_CURRENT_BUFFER);
	return yylex();
}

// kate: syntax yacc; 

