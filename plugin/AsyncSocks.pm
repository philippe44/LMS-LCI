package Plugins::LCI::AsyncSocks;

use strict;

use IO::Socket::Socks::Wrapped;
use LWP::Protocol::http;
use LWP;
	
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Data::Dumper;

my $log   = logger('plugin.LCI');
my $prefs = preferences('plugin.LCI');

#FIXME: the blocking calls when socks is used are dangerous for LMS

sub new {
	my ($class, $cb, $ecb) = @_;
	my $self = {};
	
	if ( $prefs->get('socks') ) {
	
		$self->{ua} = LWP::UserAgent->new();
		$self->{ua}->agent("LWP/6.00");
		$self->{s_ua} = IO::Socket::Socks::Wrapped->new($self->{ua}, {
				ProxyAddr => $prefs->get('socks_server'),
				ProxyPort => $prefs->get('socks_port'),
				Blocking => 0,
				SocksDebug => 0,
			});
			
		$self->{cb} = $cb;
		$self->{ecb} = $ecb;				
		
	} else {
	
		$self->{ua} = Slim::Networking::SimpleAsyncHTTP->new($cb, $ecb);
		
	}
	
	bless ($self, $class);
	
	return $self;
}

sub get {
	my $self = shift;
				
	if ( $prefs->get('socks') ) {				
		my $response = $self->{s_ua}->get(@_);
	
		if ( $response->is_success ) {
			$self->{cb}($response);
		} else {	
			$self->{ecb}(undef);
		}	
		
	} else {
	
		$self->{ua}->get(@_);
		
	}
}

sub post {
	my $self = shift;
	
	if ( $prefs->get('socks') ) {				
		my $response = $self->{s_ua}->post(@_);
	
		if ( $response->is_success ) {
			$self->{cb}($response);
		} else {	
			$self->{ecb}(undef);
		}	
		
	} else {
		
		# not the same format between LWP and AsyncHTTP ...
		my @vars = grep { $_ ne 'Content' } @_;
			
		$self->{ua}->post(@vars);
		
	}
}

sub contentRef {
	if ( $prefs->get('socks') ) {
		return shift->content_ref;
	} else {
		return shift->contentRef;
	}
}	


1;
