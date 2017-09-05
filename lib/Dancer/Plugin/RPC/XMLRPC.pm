package Dancer::Plugin::RPC::XMLRPC;
use v5.10;
use Dancer ':syntax';
use Dancer::Plugin;
use Scalar::Util 'blessed';

no if $] >= 5.018, warnings => 'experimental::smartmatch';

use Dancer::RPCPlugin::CallbackResult;
use Dancer::RPCPlugin::DispatchFromConfig;
use Dancer::RPCPlugin::DispatchFromPod;
use Dancer::RPCPlugin::DispatchItem;
use Dancer::RPCPlugin::DispatchMethodList;
use Dancer::RPCPlugin::FlattenData;

use RPC::XML::ParserFactory;

my %dispatch_builder_map = (
    pod    => \&build_dispatcher_from_pod,
    config => \&build_dispatcher_from_config,
);

register xmlrpc => sub {
    my($self, $endpoint, $arguments) = plugin_args(@_);

    my $publisher;
    given ($arguments->{publish} // 'config') {
        when (exists $dispatch_builder_map{$_}) {
            $publisher = $dispatch_builder_map{$_};
            $arguments->{arguments} = plugin_setting() if $_ eq 'config';
        }
        default {
            $publisher = $_;
        }
    }
    my $dispatcher = $publisher->($arguments->{arguments}, $endpoint);

    my $lister = Dancer::RPCPlugin::DispatchMethodList->new();
    $lister->set_partial(
        protocol => 'xmlrpc',
        endpoint => $endpoint,
        methods  => [ sort keys %{ $dispatcher } ],
    );

    my $code_wrapper = $arguments->{code_wrapper}
        ? $arguments->{code_wrapper}
        : sub {
            my $code = shift;
            my $pkg  = shift;
            $code->(@_);
        };
    my $callback = $arguments->{callback};

    debug("Starting xmlrpc-handler build: ", $lister);
    my $handle_call = sub {
        if (request->content_type ne 'text/xml') {
            pass();
        }
        debug("[handle_xmlrpc_request] Processing: ", request->body);

        local $RPC::XML::ENCODING = $RPC::XML::ENCODING ='UTF-8';
        my $p = RPC::XML::ParserFactory->new();
        my $request = $p->parse(request->body);
        my $method_name = $request->name;
        debug("[handle_xmlrpc_call($method_name)] ", $request->args);

        if (! exists $dispatcher->{$method_name}) {
            warning("$endpoint/#$method_name not found, pass()");
            pass();
        }

        content_type 'text/xml';
        my $response;
        my @method_args = map $_->value, @{$request->args};
        my Dancer::RPCPlugin::CallbackResult $continue = eval {
            $callback
                ? $callback->(request(), $method_name, @method_args)
                : callback_success();
        };

        if (my $error = $@) {
            $response = {
                faultCode => 500,
                faultString => $error,
            };
            return xmlrpc_response($response);
        }
        if (!blessed($continue) || !$continue->isa('Dancer::RPCPlugin::CallbackResult')) {
            $response = {
                faultCode   => 500,
                faultString => "Internal error: 'callback_result' wrong class " . blessed($continue),
            };
        }
        elsif (blessed($continue) && !$continue->success) {
            $response = {
                faultCode   => $continue->error_code,
                faultString => $continue->error_message,
            };
        }
        else {
            my Dancer::RPCPlugin::DispatchItem $di = $dispatcher->{$method_name};
            my $handler = $di->code;
            my $package = $di->package;

            $response = eval {
                $code_wrapper->($handler, $package, $method_name, @method_args);
            };

            debug("[handling_xmlrpc_response($method_name)] ", $response);
            if (my $error = $@) {
                $response = {
                    faultCode => 500,
                    faultString => $error,
                };
            }
            if (blessed($response) && $response->can('as_xmlrpc_fault')) {
                $response = $response->as_xmlrpc_fault;
            }
            elsif (blessed($response)) {
                $response = flatten_data($response);
            }
        }
        return xmlrpc_response($response);
    };

    debug("setting route (xmlrpc): $endpoint ", $lister);
    post $endpoint, $handle_call;
};

sub xmlrpc_response {
    my ($data) = @_;

    my $response;
    if (ref $data eq 'HASH' && exists $data->{faultCode}) {
        $response = RPC::XML::response->new(RPC::XML::fault->new(%$data));
    }
    elsif (grep /^faultCode$/, grep defined $_, @_) {
        $response = RPC::XML::response->new(RPC::XML::fault->new(@_));
    }
    else {
        $response = RPC::XML::response->new(@_);
    }
    debug("[xmlrpc_response] ", $response->as_string);
    return $response->as_string;
}

sub build_dispatcher_from_pod {
    my ($pkgs, $endpoint) = @_;
    debug("[build_dispatcher_from_pod]");
    return dispatch_table_from_pod(
        plugin   => 'xmlrpc',
        packages => $pkgs,
        endpoint => $endpoint,
    );
}

sub build_dispatcher_from_config {
    my ($config, $endpoint) = @_;
    debug("[build_dispatcher_from_config] ");

    return dispatch_table_from_config(
        plugin   => 'xmlrpc',
        config   => $config,
        endpoint => $endpoint,
    );
}

register_plugin();
true;

=head1 NAME

Dancer::Plugin::RPC::XMLRPC - XMLRPC Plugin for Dancer

=head2 SYNOPSIS

In the Controler-bit:

    use Dancer::Plugin::RPC::XMLRPC;
    xmlrpc '/endpoint' => {
        publish   => 'pod',
        arguments => ['MyProject::Admin']
    };

and in the Model-bit (B<MyProject::Admin>):

    package MyProject::Admin;
    
    =for xmlrpc rpc.abilities rpc_show_abilities
    
    =cut
    
    sub rpc_show_abilities {
        return {
            # datastructure
        };
    }
    1;

=head1 DESCRIPTION

This plugin lets one bind an endpoint to a set of modules with the new B<xmlrpc> keyword.

=head2 xmlrpc '/endpoint' => \%publisher_arguments;

=head3 C<\%publisher_arguments>

=over

=item callback => $coderef [optional]

The callback will be called just before the actual rpc-code is called from the
dispatch table. The arguments are positional: (full_request, method_name).

    my Dancer::RPCPlugin::CallbackResult $continue = $callback
        ? $callback->(request(), $method_name, @method_args)
        : callback_success();

The callback should return a L<Dancer::RPCPlugin::CallbackResult> instance:

=over 8

=item * on_success

    callback_success()

=item * on_failure

    callback_fail(
        error_code    => <numeric_code>,
        error_message => <error message>
    )

=back

=item code_wrapper => $coderef [optional]

The codewrapper will be called with these positional arguments:

=over 8

=item 1. $call_coderef

=item 2. $package (where $call_coderef is)

=item 3. $method_name

=item 4. @arguments

=back

The default code_wrapper-sub is:

    sub {
        my $code = shift;
        my $pkg  = shift;
        $code->(@_);
    };

=item publisher => <config | pod | \&code_ref>

The publiser key determines the way one connects the rpc-method name with the actual code.

=over

=item publisher => 'config'

This way of publishing requires you to create a dispatch-table in the app's config YAML:

    plugins:
        "RPC::XMLRPC":
            '/endpoint':
                'MyProject::Admin':
                    admin.someFunction: rpc_admin_some_function_name
                'MyProject::User':
                    user.otherFunction: rpc_user_other_function_name

The Config-publisher doesn't use the C<arguments> value of the C<%publisher_arguments> hash.

=item publisher => 'pod'

This way of publishing enables one to use a special POD directive C<=for xmlrpc>
to connect the rpc-method name to the actual code. The directive must be in the
same file as where the code resides.

    =for xmlrpc admin.someFunction rpc_admin_some_function_name

The POD-publisher needs the C<arguments> value to be an arrayref with package names in it.

=item publisher => \&code_ref

This way of publishing requires you to write your own way of building the dispatch-table.
The code_ref you supply, gets the C<arguments> value of the C<%publisher_arguments> hash.

A dispatch-table looks like:

    return {
        'admin.someFuncion' => dispatch_item(
            package => 'MyProject::Admin',
            code    => MyProject::Admin->can('rpc_admin_some_function_name'),
        ),
        'user.otherFunction' => dispatch_item(
            package => 'MyProject::User',
            code    => MyProject::User->can('rpc_user_other_function_name'),
        ),
    }

=back

=item arguments => <anything>

The value of this key depends on the publisher-method chosen.

=back

=head2 =for xmlrpc xmlrpc-method-name sub-name

This special POD-construct is used for coupling the xmlrpc-methodname to the
actual sub-name in the current package.

=head1 INTERNAL

=head2 xmlrpc_response

Serializes the data passed as an xmlrpc response.

=head2 build_dispatcher_from_config

Creates a (partial) dispatch table from data passed from the (YAML)-config file.

=head2 build_dispatcher_from_pod

Creates a (partial) dispatch table from data provided in POD.

=head1 COPYRIGHT

(c) MMXV - Abe Timmerman <abeltje@cpan.org>

=cut
