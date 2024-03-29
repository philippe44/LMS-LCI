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

use Encode qw(encode decode);
use Unicode::Normalize;

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
	icons   => 1,
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
		
	addChannels($client, sub {
			my $items = shift;
			
			unshift @$items, { name => cstring($client, 'PLUGIN_LCI_RECENTLYPLAYED'), image => getIcon(), url  => \&recentHandler };
			
			$callback->( $items );
		}, $args
	);
}

sub getIcon {
	my ( $class, $url ) = @_;

	return Plugins::LCI::Plugin->_pluginDataFor('icon');
}


sub recentHandler {
	my ($client, $callback, $args) = @_;
	my @menu;

	for my $item(reverse values %recentlyPlayed) {
		my $id = Plugins::LCI::ProtocolHandler::getLink($item->{'url'});
		
		if (my $lastpos = $cache->get("lci:lastpos-$id")) {
			my $position = Slim::Utils::DateTime::timeFormat($lastpos);
			$position =~ s/^0+[:\.]//;
				
			unshift  @menu, {
				name => $item->{'name'},
				image => $item->{'icon'},
				type => 'link',
				items => [ {
						title => cstring(undef, 'PLUGIN_LCI_PLAY_FROM_BEGINNING'),
						type   => 'audio',
						url    => $item->{'url'},
					}, {
						title => cstring(undef, 'PLUGIN_LCI_PLAY_FROM_POSITION_X', $position),
						type   => 'audio',
						url    => $item->{'url'} . "&lastpos=$lastpos",
					} ],
				};
		} else {		
			unshift  @menu, {
				name => $item->{'name'},
				play => $item->{'url'},
				on_select => 'play',
				image => $item->{'icon'},
				type => 'playlist',
			};
		}	
	}

	$callback->({ items => \@menu });
}


sub addChannels {
	my ($client, $cb, $args) = @_;
	my $page = "/pages/emissions/?type=other&filter=emissions-lci";
	
	Plugins::LCI::API::search( $page, sub {
		my $items = [];
		my $result = shift;
		my $data = $result->{page};
		
		$data = first { $_->{key} eq 'main' } @{$data->{data}};
		$data = first { $_->{key} eq 'body' } @{$data->{data}};
		$data = first { $_->{key} eq 'program-list' } @{$data->{data}};
		
		for my $entry (@{$data->{data}->{elementList}}) {
			my $image;
			
			$image = getImageMin( $entry->{pictures}->{elementList} ) if $prefs->get('icons');
														
			push @$items, {
				name  => $entry->{title},
				type  => 'playlist',
				url   => \&searchEpisodes,
				image 			=> $image || getIcon(),
				passthrough 	=> [ { 
					link => $entry->{link},
					artist => $entry->{channel},
					album => $entry->{title},
				} ],
				favorites_url  	=> "lciplaylist://link=$entry->{link}",
				favorites_type 	=> 'audio',
			};
			
		}
		
		@$items = sort {lc($a->{name}) cmp lc($b->{name})} @$items;
		
		#getImages(@imageList);
				
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
		my $data = $result->{page};
		
		$data = first { $_->{key} eq 'main' } @{$data->{data}};
		$data = first { $_->{key} eq 'body' } @{$data->{data}};
		$data = first { $_->{key} eq 'program-video-list' } @{$data->{data}};

		for my $entry (@{$data->{data}->{elementList}}) {		
			my ($date) =  ($entry->{date} =~ m/(\S*)T/);
			my $image = getImageMin( $entry->{pictures}->{elementList} ) if $prefs->get('icons');	
			
			my $title;
			$title = $1 if $entry->{title} =~ m/-(.*)-/;
			$title ||= $entry->{title};
			
			my $meta = $cache->get("lci:meta-$entry->{link}");
			unless (defined $meta->{artist}) {
				$meta->{artist} = $params->{artist};
				$meta->{album} = $params->{album};
				$cache->set("lci:meta-$entry->{link}", $meta);
			}	
			
			if (my $lastpos = $cache->get("lci:lastpos-" . $entry->{link})) {
				my $position = Slim::Utils::DateTime::timeFormat($lastpos);
				$position =~ s/^0+[:\.]//;
				
				push @$items, {
					name 		=> $title,
					type 		=> 'link',
					image 		=> $image || getIcon(),
					items => [ {
						title => cstring(undef, 'PLUGIN_LCI_PLAY_FROM_BEGINNING'),
						type   => 'audio',
						url    => "lci:$entry->{link}",
					}, {
						title => cstring(undef, 'PLUGIN_LCI_PLAY_FROM_POSITION_X', $position),
						type   => 'audio',
						url    => "lci:$entry->{link}&lastpos=$lastpos",
					} ],
				};
			} else {
				push @$items, {
					name 		=> $title,
					type 		=> 'playlist',
					on_select 	=> 'play',
					play 		=> "lci:$entry->{link}",
					image 		=> $image || getIcon(),
				};
			}

		}	
					
		$cb->( $items );
		
	} );
}

sub getImageMin {
	my ($list) = @_;
	
	return undef if !defined $list;
	
	# We have an  images array. Each image array contains different height. 
	my @images = sort { $a->{height} <=> $b->{height} } @{$list};
	my $url = Encode::decode( 'utf-8', $images[0]->{url} );
	
	return $url;
}

=comment
sub getImages {
	my (@list) = @_;
	
	# We have a channel array of images array. Each image array contains different
	# height. Then each heigh contains different dpi. Need ptp take smallest of all
	# They might already be sorted, but can't count on that.
	
	for my $item (@list) {
		my @images = sort { $a->{height} <=> $b->{height} } @{$item};
		my @dpi = sort { $a->{size} <=> $b->{size} } @{$images[0]->{dpi}};
		my $url = $dpi[0]->{url};
		
		$log->error($url);		
	}
	
}
=cut


1;
