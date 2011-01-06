package Plack::Client;
use strict;
use warnings;

use HTTP::Message::PSGI;
use HTTP::Request;
use Plack::App::Proxy;
use Plack::Middleware::ContentLength;
use Plack::Response;
use Scalar::Util qw(blessed);

sub new {
    my $class = shift;
    my %params = @_;

    die 'XXX' if exists($params{apps}) && ref($params{apps}) ne 'HASH';

    bless {
        apps => $params{apps},
    }, $class;
}

sub apps { shift->{apps} }

sub app_for {
    my $self = shift;
    my ($for) = @_;
    return $self->apps->{$for};
}

sub request {
    my $self = shift;
    my $req = blessed($_[0]) && ($_[0]->isa('HTTP::Request')
                              || $_[0]->isa('Plack::Request'))
                  ? $_[0]
                  : ref($_[0]) eq 'HASH'
                      ? Plack::Request->new(@_)
                      : HTTP::Request->new(@_);

    # both Plack::Request and HTTP::Request have a ->uri method
    my $scheme = $req->uri->scheme;
    my $app;
    if ($scheme eq 'psgi-local') {
        if ($req->isa('Plack::Request')) {
            $req->env->{REQUEST_URI} = '/' unless length $req->request_uri;
        }
        else {
            $req->uri->path('/') unless length $req->uri->path;
        }
        my $app_name = $req->uri->authority;
        $app_name =~ s/:.*//;
        $app = $self->app_for($app_name);
        $app = Plack::Middleware::ContentLength->wrap($app);
    }
    elsif ($scheme eq 'http' || $scheme eq 'https') {
        my $uri = $req->uri->clone;
        $uri->path('/');
        $app = Plack::App::Proxy->new(remote => $uri->as_string)->to_app;
    }

    die 'XXX' unless $app;

    my $env = $self->_req_to_env($req);
    my $psgi_res = $self->_resolve_response($app->($env));
    # is there a better place to do this? Plack::App::Proxy already takes care
    # of this (since it's making a real http request)
    $psgi_res->[2] = [] if $env->{REQUEST_METHOD} eq 'HEAD';

    # XXX: or just return the arrayref?
    return Plack::Response->new(@$psgi_res);
}

sub _req_to_env {
    my $self = shift;
    my ($req) = @_;

    my $env;
    if ($req->isa('HTTP::Request')) {
        my $scheme = $req->uri->scheme;
        # hack around with this - psgi requires a host and port to exist, and
        # for the scheme to be either http or https
        if ($scheme eq 'psgi-local') {
            $req->uri->scheme('http');
            $req->uri->host('Plack::Client');
            $req->uri->port(-1);
        }
        elsif ($scheme eq 'psgi-local-ssl') {
            $req->uri->scheme('https');
            $req->uri->host('Plack::Client');
            $req->uri->port(-1);
        }
        elsif ($scheme ne 'http' && $scheme ne 'https') {
            die 'XXX';
        }

        $env = $req->to_psgi;
    }
    else {
        $env = $req->env;
    }

    # work around http::message::psgi bug - see github issue 150 for plack
    $env->{CONTENT_LENGTH} ||= length($req->content);

    return $env;
}

sub _resolve_response {
    my $self = shift;
    my ($psgi_res) = @_;

    if (ref($psgi_res) eq 'CODE') {
        my $body = '';
        $psgi_res->(sub {
            $psgi_res = shift;
            return Plack::Util::inline_object(
                write => sub { $body .= $_[0] },
                close => sub { push @$psgi_res, $body },
            );
        });
    }

    use Data::Dumper; die Dumper($psgi_res) unless ref($psgi_res) eq 'ARRAY';

    return $psgi_res;
}

sub get    { shift->request('GET',    @_) }
sub head   { shift->request('HEAD',   @_) }
sub post   { shift->request('POST',   @_) }
sub put    { shift->request('PUT',    @_) }
sub delete { shift->request('DELETE', @_) }

1;
