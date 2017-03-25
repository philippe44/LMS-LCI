package Plugins::LCI::ProtocolHandler;
use base qw(IO::Handle);

use strict;

use List::Util qw(min max first);
use HTML::Parser;
use URI::Escape;
use Scalar::Util qw(blessed);
use JSON::XS;
use Data::Dumper;
use Digest::MD5 qw(md5 md5_hex md5_base64);
use MIME::Base64;
use Encode qw(encode decode find_encoding);
use LWP;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;
use Slim::Networking::Async::HTTP;

use IO::Socket::Socks;
use IO::Socket::Socks::Wrapped;
use Plugins::LCI::AsyncSocks;
use Plugins::LCI::MPEGTS;

# streaming states
use constant SYNCHRO     => 1;
use constant PIDPAT	     => 2;
use constant PIDPMT	     => 3;
use constant AUDIO	     => 4;

my $log   = logger('plugin.LCI');
my $prefs = preferences('plugin.LCI');
my $cache = Slim::Utils::Cache->new;

use constant API_URL => "http://api.lci.fr";
use constant API_URL_GLOBAL => 'http://webservices.francetelevisions.fr';

Slim::Player::ProtocolHandlers->registerHandler('lci', __PACKAGE__);

sub new {
	my $class = shift;
	my $args  = shift;
	my $song  = $args->{'song'};
	my $index = 0;
	my ($server, $port) = Slim::Utils::Misc::crackURL(@{$song->pluginData('streams')}[0]->{url});
	my $seekdata   = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
		
	if ( my $newtime = $seekdata->{'timeOffset'} ) {
		my $streams = \@{$args->{song}->pluginData('streams')};
		
		$index = first { $streams->[$_]->{position} >= int $newtime } 0..scalar @$streams;
		
		$song->can('startOffset') ? $song->startOffset($newtime) : ($song->{startOffset} = $newtime);
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $newtime);
	}

	my $self = $class->SUPER::new;
	
	if (defined($self)) {
		${*$self}{'song'}    = $args->{'song'};
		${*$self}{'vars'} = {         # variables which hold state for this instance: (created by "open")
			'inBuf'       => undef,   #  buffer of received flv packets/partial packets
			'state'       => SYNCHRO, #  expected protocol fragment
			'index'  	  => $index,  #  current index in fragments
			'fetching'    => 0,		  #  flag for waiting chunk data
			'pos'		  => 0,		  #  position in the latest input buffer
		};
	}

	return $self;
}

sub contentType { 'aac' }
	
sub formatOverride {
	my $class = shift;
	my $song = shift;

	return $song->pluginData('format') || 'aac';
}

sub isAudio { 1 }

sub isRemote { 1 }

sub songBytes { }

sub canSeek { 1 }

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;

	return { timeOffset => $newtime };
}

sub vars {
	return ${*{$_[0]}}{'vars'};
}

sub sysread {
	use bytes;

	my $self  = $_[0];
	# return in $_[1]
	my $maxBytes = $_[2];
	my $v = $self->vars;
		
	# waiting to get next chunk, nothing sor far	
	if ( $v->{'fetching'} ) {
		$! = EINTR;
		return undef;
	}
			
	# end of current segment, get next one
	if ( !defined $v->{'inBuf'} || $v->{'pos'} == length ${$v->{'inBuf'}} ) {
	
		# end of stream
		return 0 if $v->{index} == scalar @{${*$self}{song}->pluginData('streams')};
		
		# get next fragment/chunk
		my $url = @{${*$self}{song}->pluginData('streams')}[$v->{index}]->{url};
		$v->{index}++;
		$v->{'pos'} = 0;
		$v->{'fetching'} = 1;
						
		$log->info("fetching: $url");
			
		Plugins::Pluzz::AsyncSocks->new(
			sub {
				$v->{'inBuf'} = $_[0] = Plugins::Pluzz::AsyncSocks::contentRef($_[0]);
				$v->{'fetching'} = 0;
				$log->debug("got chunk length: ", length ${$v->{'inBuf'}});
			},
			
			sub { 
				$log->warn("error fetching $url");
				$v->{'inBuf'} = undef;
				$v->{'fetching'} = 0;
			}, 
			
		)->get($url);
			
		$! = EINTR;
		return undef;
	}	
				
	my $len = Plugins::LCI::MPEGTS::processTS($v, \$_[1], $maxBytes);
			
	return $len if $len;
	
	$! = EINTR;
	return undef;
}


sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $url 	 = $song->track()->url;
	my $client   = $song->master();
	my $link	 = $class->getLink($url);
	
	$log->info("getNextTrack : $url (link: $link)");
	
	if (!$link) {
		$errorCb->();
		return;
	}	
			
	getFragments( 
	
		sub {
			my $fragments = shift;
			
			return $errorCb->() unless (defined $fragments && scalar @$fragments);
			
			my ($server) = Slim::Utils::Misc::crackURL( $fragments->[0]->{url} );
			
			$song->pluginData(streams => $fragments);	
			$song->pluginData(stream  => $server);
			$song->pluginData(format  => 'aac');
			$song->track->secs( $fragments->[scalar @$fragments - 1]->{position} );
			$class->getMetadataFor($client, $url, undef, $song);
			
			$successCb->();
		} , $link 
		
	);
}	


sub getFragments {
	my ($cb, $link) = @_;
	my $url = API_URL . "/pages/$link?device=ios-smartphone" ;
	my $params;
		
	# get the watId	
	Plugins::LCI::AsyncSocks->new ( 
			sub {
				my $data = decode_json(shift->content);
								
				$data = $data->{page}->{data};
				$data = first { $_->{key} eq 'main' } @{$data};
				$data = first { $_->{key} eq 'article-header-video' } @{$data->{data}};
				$params->{watId} = $data->{data}->{video}->{watId};
				
				$log->info("watId: $params->{watId}");
				
				getMessage($cb, $params);
			},	
			
			sub {
				$cb->(undef);
			}
					
	)->get($url);
	
	# get server timestamp
	Plugins::LCI::AsyncSocks->new ( 
			sub {
				my $res = shift->content;
			
				$res =~ /([^|]+)/;
				$params->{timestamp} = encode('UTF-8', $1);
												
				$log->info("authKey: $params->{timestamp}");
				
				getMessage ($cb, $params);
			},	
			
			sub {
				$cb->(undef);
			}
					
	)->get('http://www.wat.tv/servertime');
}


sub getMessage {
	my ($cb, $params) = @_;
	
	# need to wait for both async queries
	return if !$params->{watId} || !$params->{timestamp};
	
	# okay, got what we need for next step
	my $req = Plugins::LCI::AsyncSocks->new ( 
		sub {
			my $res = decode_json(shift->content);
				
			$log->info("master M3U url: $res->{message}");
			
			getMasterM3U($cb, $res->{message});
		},	
			
		sub {
			$cb->(undef);
		}
	);
	
	my $secret = decode_base64('VzNtMCMxbUZJ');
	my $appName = "sdk/Iphone/1.0";
	my $authKey = md5_hex( "$params->{watId}-$secret-$appName-$secret-$params->{timestamp}" ) . "/$params->{timestamp}";
	
	my $content = "udid=01860F72-DF58-4703-A437-BDE226EE2C82" .
				"&useragent=Mozilla/5.0 (iPhone; U; CPU like Mac OS X; en) AppleWebKit/XX (KHTML, like Gecko)" .
				"&context=WIFI" .
				"&deviceType=sph" .
				"&mediaId=$params->{watId}" .
				"&appName=$appName" .
				"&authKey=$authKey" .
				"&method=getDownloadUrl";
				
	# this will give the URL where to find the m3u file			
	$req->post( 'http://api.wat.tv/services/Delivery', 
			    'User-Agent' => 'MYTF1 4.1.2 rv:60010000.384 (iPod touch; iPhone OS 6.1.5; fr_FR)',
			    'Content-Type' => 'application/x-www-form-urlencoded',
			    'Content' => $content );
}


sub getMasterM3U {
	my ($cb, $url) = @_;
	
	my $http = Slim::Networking::Async::HTTP->new;
	my $request = HTTP::Request->new( GET => $url );
	$request->header( 'User-Agent' => "AppleCoreMedia/1.0.0.10B400 (iPod; U; CPU OS 6_1_5 like Mac OS X; fr_fr)" );		
	
	$url =~ /(.*\/)/;	
	my $base = $1;
	
	# need to obtain the redirect URI first
	$http->send_request( {
		request     => $request,
		
		onRedirect  => sub {
			$base = shift->uri;
			$base =~ /(.*\/)/;	
			$base = $1;
			$log->debug("redirected base: $base");
		},
		
		onBody  => sub {
			my $m3u = shift->response->content;
			my $slaveUrl;
			my $bw;
				
			$log->debug("master M3U: $m3u");
				
			for my $item ( split (/#EXT-X-STREAM-INF:/, $m3u) ) {
				next if $item !~ m/BANDWIDTH=(\d+)([^\n]+)\n(.*)/s;
				if (!defined $bw || $1 < $bw) {
					$bw = $1;
					$slaveUrl = $3;
				} 	
			}
				
			$log->info("slave M3U url: $base" . "$slaveUrl");
	
			getFragmentList($cb, $base . $slaveUrl);
		},
		
		onError     => sub { $cb->( undef ); },
	} );
}	


sub getFragmentList {
	my ($cb, $url) = @_;
	
	Plugins::LCI::AsyncSocks->new ( 
		sub {
			my $fragmentList = shift->content;
			my @fragments;
			my $position = 0;
			$url =~ /(.*\/)/;
			my $base = $1;
					
			for my $item ( split (/#EXTINF:/, $fragmentList) ) {
				$item =~ m/([^\n]+)\n(.+ts)/s;
				$position += $1 if $2;
				push @fragments, { position => $position, url => $base . $2 } if $2;
			}	
														
			$cb->(\@fragments);
		},	
			
		sub {
			$cb->(undef);
		}
					
	)->get( $url, 'User-Agent' => 'AppleCoreMedia/1.0.0.10B400 (iPod; U; CPU OS 6_1_5 like Mac OS X; fr_fr)' );
	
}


sub suppressPlayersMessage {
	my ($class, $client, $song, $string) = @_;

	# suppress problem opening message if we have more streams to try
	if ($string eq 'PROBLEM_OPENING' && scalar @{$song->pluginData('streams') || []}) {
		return 1;
	}

	return undef;
}


sub getMetadataFor {
	my ($class, $client, $url, undef, $song) = @_;
	my $icon = $class->getIcon();

	return {	
			type	=> 'LCI',
			title	=> "LCI",
			icon	=> $icon,
			cover	=> $icon,
	};
}	
=comment	
	main::DEBUGLOG && $log->debug("getmetadata: $url");
			
	my ($id, $channel, $program) = $class->getId($url);
	return unless $id && $channel && $program;
	
	if (my $meta = $cache->get("pz:meta-$id")) {
		$song->track->secs($meta->{'duration'}) if $song;
				
		Plugins::LCI::Plugin->updateRecentlyPlayed({
			url   => $url, 
			name  => $meta->{_fulltitle} || $meta->{title}, 
			icon  => $meta->{icon},
		});

		main::DEBUGLOG && $log->debug("cache hit: $id");
		
		return $meta;
	}
	
	Plugins::LCI::API->searchEpisode( sub {
		my $result = shift;
		my $item = 	first { $_->{id_diffusion} eq $id } @{$result || []};
						
		$song->track->secs($item->{duree_reelle}) if $song;
				
		if ($client) {
			$client->currentPlaylistUpdateTime( Time::HiRes::time() );
			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
		}	
						
	}, { channel => $channel, code_programme => $program } );
	
	return {	
			type	=> 'LCI',
			title	=> "LCI",
			icon	=> $icon,
			cover	=> $icon,
	};
}	
=cut

	
sub getIcon {
	my ( $class, $url ) = @_;

	return Plugins::LCI::Plugin->_pluginDataFor('icon');
}


sub getLink {
	my ($class, $url) = @_;

	if ($url =~ m|lci:(.+)|) {
		return $1;
	}
		
	return undef;
}


1;
