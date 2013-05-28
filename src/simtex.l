%{
#include <getopt.h>
#include <iostream>
#include <string>
#include <map>
#include <set>
#include <vector>
#include <sstream>

#ifdef DEBUG
#define LOG(ARG...)		std::clog<<ARG
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
	Ifdef		= 1 << 6,
	Condition	= 1 << 7,
};

/* Context is used to represent the current parsing state of a specific buffer.
The buffers are organised as a stack, with the top Context being the active one.
All buffers below the current stack are suspended. When the current context
is popped from the stack, the next Context wakes up, and resumes its parsing.
*/
struct Context
{
	// defkey is used to remember the current $def key
	std::string defkey;
	// env represents all the key -> value mappings
	std::map<std::string, std::string> env;
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
	std::set<std::string> derived;
	// if file is not null, the buffer is being read from the file
	FILE* file;
	
	Context(YY_BUFFER_STATE b, FILE* f = NULL, int a = 0)
	: buffer(b)
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

std::vector<std::string> files;
std::vector<Context*> stack;

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
void pushfile(const std::string& filename, int action);
void pushstring(const std::string& string, int action);
void insertfile(const std::string& filename, int action);

/* This copies the env keyvalues from a to b.
If b is marked as an inherited (ie. base) context, the keys are added to its derived
member. The derived member is used in turn to detect whether a key has been specified
by a derived context, so that overwriting by the base context can be prevented.
*/
void copy(Context* a, Context* b)
{
	for (std::map<std::string, std::string>::iterator i = a->env.begin(); i != a->env.end(); ++i)
	{
		TRACE("copying key ["<<i->first<<"] = '"<<i->second<<"'");
		b->env[i->first] = i->second;
		if (b->base)
			b->derived.insert(i->first);
	}
	if (b->base)
		TRACE("marking all as derived");
}

bool defined(const std::string& key)
{
	// start at the back, and look for the key
	for (std::vector<Context*>::reverse_iterator s = stack.rbegin(); s != stack.rend(); ++s)
	{
		std::map<std::string, std::string>::iterator i = (*s)->env.find(key);
		if (i != (*s)->env.end()) return true;
	}
	return false;
}

/* This function returns the value of a requested key.
The stack is traversed from top to bottom, and if no key is found, value() returns either
the empty string, the key name verbatim or throws an error, depending on the configuration.
TODO: implement this!
*/
std::string value(const std::string& key)
{
	// start at the back, and look for the key[1:]
	// TODO: fix this so that the caller takes care of cleanup up the name!
	for (std::vector<Context*>::reverse_iterator s = stack.rbegin(); s != stack.rend(); ++s)
	{
		std::map<std::string, std::string>::iterator i = (*s)->env.find(key);
		if (i != (*s)->env.end()) return i->second;
	}
	return "";
}
/* Store will overwrite the key with name current->defkey using the provided value.
This is prevented when the key is in the derived set, however.
*/
void store(const std::string& value)
{
	std::set<std::string>::iterator i = current().derived.find(current().defkey);
	if (i == current().derived.end())
	{
		TRACE("storing ["<<current().defkey<<"] = '"<<value<<"'");
		current().env[current().defkey] = value;
	}
	else
		TRACE("ignoring derived keyvalue");
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
%option stack
%%
<<EOF>>			{					// match end of file
					TRACE("<<EOF>>");
					if (popbuffer()) yyterminate();
		        }
[\$\\]\$		{					// match "$$" or "\$"
					TRACE("replacing escaped $");
					OUTPUT('$');
				}
\$\([a-zA-Z_]+[a-zA-Z0-9_]*\)	{	// match "$(...)"
					std::string text = std::string(yytext);
					text = text.substr(2, text.length()-3); // strip the $( and )
					TRACE("$(key) reference ["<<text<<"]");
					OUTPUT(value(text));
				}
\$[a-zA-Z_]+[a-zA-Z0-9_]*	{		// match "$..."
					std::string text = std::string(yytext);
					text = text.substr(1); // strip the $
					TRACE("$key reference ["<<text<<"]");
					OUTPUT(value(text));
				}
\$def[ \t]+		{					// match "$def", eating up any trailing whitespace
					TRACE("found $def");
					pushstate(DEFKEY);
				}
<DEFKEY>[^ \t]*[ \t]+ {				// match a run of non-whitespace, followed by whitespace - ie. a single word
					std::string text = std::string(yytext);
					size_t b = text.find_last_not_of(" \t");
					text = text.substr(0, b+1);
					TRACE("def key text ["<<text<<"]");
					setstate(DEFVAL);
					pushstring(text, DefineKey);
				}
<DEFVAL>.*\n	{					// match the rest of the line
					std::string text = std::string(yytext, strlen(yytext)-1);
					TRACE("def value text ["<<text<<"]");
					popstate(); // ex-DEFVAL
					pushstring(text, DefineValue);
				}
\$include[ \t]+	{					// match "$include", eating up any trailing whitespace
					TRACE("found $include");
					pushstate(INCLUDE);
				}
<INCLUDE>.*\n	{					// match the rest of the line
					std::string text = std::string(yytext, strlen(yytext)-1);
					TRACE("include text ["<<text<<"]");
					popstate(); // ex-INCLUDE
					pushstring(text, Include | Filename);
				}
\$import[ \t]+	{					// match "$import", eating up any trailing whitespace
					TRACE("found $import");
					pushstate(IMPORT);
				}
<IMPORT>.*\n	{					// match the rest of the line
					std::string text = std::string(yytext, strlen(yytext)-1);
					TRACE("import text ["<<text<<"]");
					popstate(); // ex-IMPORT
					pushstring(text, Import | Filename);
				}
\$inherit[ \t]+	{					// match "$inherit", eating up any trailing whitespace
					TRACE("found $inherit");
					pushstate(INHERIT);
				}
<INHERIT>.*\n	{					// match the rest of the line
					std::string text = std::string(yytext, strlen(yytext)-1);
					TRACE("inherit text ["<<text<<"]");
					popstate(); // ex-INHERIT
					pushstring(text, Inherit | Filename);
				}
\$ifdef[ \t]+	{					// match "$ifdef", eating up any trailing whitespace
					TRACE("found $ifdef");
					pushstate(IFDEF);
				}
<IFDEF>.*\n		{					// match the rest of the line
					std::string text = std::string(yytext, strlen(yytext)-1);
					TRACE("ifdef text ["<<text<<"]");
					popstate(); // ex-IFDEF
					pushstring(text, Ifdef | Condition);
				}
<ENDIF>.		{					// matches any character in endif mode
					// discard active endif block
					std::clog<<"{"<<yytext<<"}";
				}
<ENDIF>$endif[ \t]*\n {				// matches active $endif line
					TRACE("found active endif");
					setstate(INITIAL);
				}
$endif[ \t]*\n	{		 			// matches $endif line
					TRACE("found inactive endif");
				}					
.				{					// match any leftover character
					OUTPUT(yytext); 
				}
\n				{					// match the end-of-line
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

bool nextfile()
{
	// check whether the filelist is empty
	if (files.empty()) return false;
	std::string filename = files.back();
	files.pop_back();
	TRACE("opening list file ["<<filename<<"]");
	FILE* f = NULL;
	f = (filename == "-") ? stdin : fopen(filename.c_str(), "r");
	if (!f)
	{
		std::cerr<<"ERR: Failed to open file ["<<filename<<"]"<<std::endl;
		exit(1);
	}
	stack.push_back(new Context(yy_create_buffer(f, YY_BUF_SIZE), f));
	pushstate(INITIAL);
	return true;
}

int popbuffer()
{
	Context* context = stack.back();
	TRACE("popping stack, size is "<<stack.size());
	stack.pop_back();
	if (stack.empty())
	{
		TRACE("output:::::::::");
		std::cout<<context->output.str()<<std::flush;
		TRACE("stack is empty");
		if (!nextfile())
		{
			delete context;
			return 1;
		}
	}
	yy_switch_to_buffer(current().buffer);
	popstate();
	copy(context, stack.back());
	std::string value = context->output.str();
	switch (current().action)
	{
		case DefineKey:
			TRACE("def key ["<<value<<"]");
			current().defkey = value;
			break;
		case DefineValue:
			TRACE("def value ["<<value<<"]");
			store(value);
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
			TRACE("adding $DERIVED output ["<<value<<"]");
			// note, we chop the trailing newline, so that we don't have any unwanted spacing
			current().env["DERIVED"] = value.substr(0, value.length()-1);
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
		default:
			TRACE("discarding output ["<<value<<"]");
			break;
	}
	delete context;
	printstack();
	TRACE("current buffer is "<<YY_CURRENT_BUFFER);
	printstate();
	return 0;
}

void pushstring(const std::string& string, int action)
{
	TRACE("pushing string buffer");
    current().buffer = YY_CURRENT_BUFFER;
    current().action = action;
    stack.push_back(new Context(yy_scan_string(string.c_str())));
    //
    // this is already done by yy_scan_string: yy_switch_to_buffer(current().buffer);
	pushstate(INITIAL);
	printstack();
	printstate();
	TRACE("current buffer is "<<YY_CURRENT_BUFFER);
}
void pushfile(const std::string& filename, int action)
{
	TRACE("pushing file buffer");
    current().buffer = YY_CURRENT_BUFFER; // back up the current buffer
    current().action = action; // remember the action
    FILE* f = fopen( filename.c_str(), "r" );
    if (!f)
    {
    	std::cerr<<"ERR: Failed to open included file ["<<filename<<"]"<<std::endl;
    	exit(1);
    }
    stack.push_back(new Context(yy_create_buffer(f, YY_BUF_SIZE), f));
    //
    yy_switch_to_buffer(current().buffer);
	pushstate(INITIAL);
	printstack();
	printstate();
	TRACE("current buffer is "<<YY_CURRENT_BUFFER);
}
void insertfile(const std::string& filename, int action)
{
	TRACE("inserting file buffer");
	// insert the requested buffer *behind* the current one
    FILE* f = fopen(filename.c_str(), "r");
    if (!f)
    {
    	std::cerr<<"ERR: Failed to open included file ["<<filename<<"]"<<std::endl;
    	exit(1);
    }
    std::vector<Context*>::iterator i = stack.end() - 1;
	stack.insert(i, new Context(yy_create_buffer(f, YY_BUF_SIZE), f, action));
	//
    yy_switch_to_buffer(current().buffer);
	pushstate(INITIAL);
	printstack();
	printstate();
	TRACE("current buffer is "<<YY_CURRENT_BUFFER);
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

	optind = 0;
	int c = 0;
	while ((c = getopt (argc, argv, "")) != -1)
	{
		switch (c)
		{
			// TODO: add future options
			/* these could include:
			-d			: add comments for debugging
			-D CMNT		: use CMNT string before comments (default is "#")
			-r			: relaxed mode: ignore missing files
			-s			: strict mode: abort if a key is used but not defined
			-I PATH		: add the search path for include/import/inherit files
			-o OUTPUT	: output to the specified file (instead of stdout)
			*/
			default:
				usage(argv[0], -1);
				break;
		}
	}
	
	if (optind == argc)
	{
		// if no filelist was specified, use stdin. This is already set up for us by flex
		TRACE("no filelist, using stdin");
		stack.push_back(new Context(YY_CURRENT_BUFFER));
	}
	else
	{
		// push the file list onto the stack
		TRACE("filelist provided");
		// these will be treated as if each in turn had $include'ed the one after
		for (int i = argc-1; i >= optind; --i)
		{
			TRACE("pushing file ["<<argv[i]<<"]");
			files.push_back(argv[i]);
		}
		nextfile();
	}
	yy_switch_to_buffer(current().buffer);
	
    TRACE("initting with buffer "<<current().buffer);
	TRACE("stack size: "<<stack.size());
	printstack();
	TRACE("current buffer is "<<YY_CURRENT_BUFFER);
	return yylex();
}

// kate: syntax yacc; 
