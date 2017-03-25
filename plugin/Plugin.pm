package Plugins::LCI::Plugin;

# Plugin to stream audio from LCI videos streams
#
# Released under GPLv2

use strict;
use base qw(Slim::Plugin::OPMLBased);
use File::Spec::Functions;
use List::Util qw(min max first);

use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'LCI', 'lib');
use IO::Socket::Socks;

use Data::Dumper;
use Encode qw(encode decode);

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::LCI::API;
use Plugins::LCI::ProtocolHandler;
use Plugins::LCI::ListProtocolHandler;

my $WEBLINK_SUPPORTED_UA_RE = qr/iPeng|SqueezePad|OrangeSqueeze/i;

my	$log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.LCI',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_LCI',
});

my $prefs = preferences('plugin.LCI');
my $cache = Slim::Utils::Cache->new;

$prefs->init({ 
	recent => [], 
});

tie my %recentlyPlayed, 'Tie::Cache::LRU', 50;

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed   => \&toplevel,
		tag    => 'LCI',
		menu   => 'radios',
		is_app => 1,
		weight => 10,
	);

	if ( main::WEBUI ) {
		require Plugins::LCI::Settings;
		Plugins::LCI::Settings->new;
	}
	
	for my $recent (reverse @{$prefs->get('recent')}) {
		$recentlyPlayed{ $recent->{'url'} } = $recent;
	}
	
#        |requires Client
#        |  |is a Query
#        |  |  |has Tags
#        |  |  |  |Function to call
	Slim::Control::Request::addDispatch(['LCI', 'info'], 
		[1, 1, 1, \&cliInfoQuery]);
		
	
}

sub shutdownPlugin {
	my $class = shift;

	$class->saveRecentlyPlayed('now');
}

sub getDisplayName { 'PLUGIN_LCI' }

sub updateRecentlyPlayed {
	my ($class, $info) = @_;

	$recentlyPlayed{ $info->{'url'} } = $info;

	$class->saveRecentlyPlayed;
}

sub saveRecentlyPlayed {
	my $class = shift;
	my $now   = shift;

	unless ($now) {
		Slim::Utils::Timers::killTimers($class, \&saveRecentlyPlayed);
		Slim::Utils::Timers::setTimer($class, time() + 10, \&saveRecentlyPlayed, 'now');
		return;
	}

	my @played;

	for my $key (reverse keys %recentlyPlayed) {
		unshift @played, $recentlyPlayed{ $key };
	}

	$prefs->set('recent', \@played);
}

sub toplevel {
	my ($client, $callback, $args) = @_;
	
	my $items = [ { name => cstring($client, 'PLUGIN_LCI_RECENTLYPLAYED'), image => getIcon(), url  => \&recentHandler, } ];
		
	addChannels($client, $callback, $args, $items);
}

sub getIcon {
	my ( $class, $url ) = @_;

	return Plugins::LCI::Plugin->_pluginDataFor('icon');
}


sub recentHandler {
	my ($client, $callback, $args) = @_;

	my @menu;

	for my $item(reverse values %recentlyPlayed) {
		unshift  @menu, {
			name => $item->{'name'},
			play => $item->{'url'},
			on_select => 'play',
			image => $item->{'icon'},
			type => 'playlist',
		};
	}

	$callback->({ items => \@menu });
}


sub addChannels {
	my ($client, $cb, $args, $items) = @_;
	my $page = "/pages/emissions/?type=other&filter=emissions-lci";
	
	Plugins::LCI::API::search( $page, sub {
	
		my $result = shift;
		my $data = $result->{page}->{data};
		$data = first { $_->{key} eq 'main' } @{$data};
		$data = first { $_->{key} eq 'emission-milestone' } @{$data->{data}};
		
		for my $entry (@{$data->{data}->{elementList}}) {
							
			push @$items, {
				name  => $entry->{text},
				type  => 'playlist',
				url   => \&searchEpisodes,
				#image => $entry->{pictures}->{elementList}[0]->{dpi}[0]->{url},
				passthrough 	=> [ { link => $entry->{link} } ],
				favorites_url  	=> "lciplaylist://link=$entry->{link}",
				favorites_type 	=> 'audio',
			};
			
		}
		
		@$items = sort {lc($a->{name}) cmp lc($b->{name})} @$items;
		
		$cb->( $items );
	
	} );	
}	
	

sub searchEpisodes {
	my ($client, $cb, $args, $params) = @_;
	my $page = "/pages$params->{link}";
	
	$log->info("fetching $page");
	
	Plugins::LCI::API::search( $page, sub {
		my $result = shift;
		my $items = [];
		
		my $data = $result->{page}->{data};
		$data = first { $_->{key} eq 'main' } @{$data};
		$data = first { $_->{key} eq 'topic-emission-extract' } @{$data->{data}};
			
		my @list = grep { $_->{type} =~ 'catchup' } @{$data->{data}->{elementList}};
		unshift @list, $data->{data} if ($data->{data}->{type} =~ 'catchup');
		@list = sort {lc($b->{date}) cmp lc($a->{date})} @list;
						
		for my $entry (@list) {
			my ($date) =  ($entry->{date} =~ m/(\S*)T/);
						
			push @$items, {
				name 		=> $entry->{title},
				type 		=> 'playlist',
				on_select 	=> 'play',
				play 		=> "lci:$entry->{link}",
				#image 		=> $entry->{pictures}->{elementList}[0]->{dpi}[0]->{url},
			};
			
		}
		
		$cb->( $items );
		
	} );
}


1;
