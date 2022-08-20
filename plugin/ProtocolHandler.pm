package Plugins::LCI::ProtocolHandler;
use base qw(IO::Handle);

use strict;

use List::Util qw(min max first);
use JSON::XS;
use XML::Simple;
use Digest::MD5 qw(md5 md5_hex md5_base64);
use MIME::Base64;
use Encode qw(encode decode find_encoding);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;
use Slim::Networking::Async::HTTP;

use Plugins::LCI::m4a;
use Plugins::LCI::API;

use constant DEFAULT_CACHE_TTL => 24 * 3600;
use constant HLS_UA => 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.1.1 Mobile/15E148 Safari/604.1';  
use constant MPD_UA => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/51.0.2704.103 Safari/537.36';

my $log   = logger('plugin.LCI');
my $prefs = preferences('plugin.LCI');
my $cache = Slim::Utils::Cache->new;

Slim::Player::ProtocolHandlers->registerHandler('lci', __PACKAGE__);

sub new {
	my $class = shift;
	my $args  = shift;
	my $song  = $args->{'song'};
	my ($index, $offset, $repeat) = (0, 0, 0);
	my $seekdata = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
	my $params = $song->pluginData('params');
	
	$log->debug("params ", Data::Dump::dump($params));
	
	# erase last position from cache
	$cache->remove('lci:lastpos-' . $args->{'url'});
	
	if ( my $newtime = ($seekdata->{'timeOffset'} || $song->pluginData('lastpos')) ) {
		if (my $segments = $song->pluginData('segments')) {
			TIME: foreach (@{$segments}) {
				$offset = $_->{t} if $_->{t};
				for my $c (0..$_->{r} || 0) {
					$repeat = $c;
					last TIME if $offset + $_->{d} > $newtime * $params->{timescale};
					$offset += $_->{d};				
				}	
				$index++;			
			}
		} else {
			$index = int($newtime / ($params->{d} / $params->{timescale}));
		}	
				
		$song->can('startOffset') ? $song->startOffset($newtime) : ($song->{startOffset} = $newtime);
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $newtime);
	}

	my $self = $class->SUPER::new;
	return unless $self;
	
	# context that will be used
	my $vars = {
			'inBuf'       => undef,   # (reference to) buffer of received packets
			'index'  	  => $index,  # current index in segments
			'offset'	  => $offset, # time offset, maybe be used to build URL
			'fetching'    => 0,		  # flag for waiting chunk data
			'retry'		  => 5,
			'context' 	  => { },	  # context for mp4		
			'repeat'      => $repeat, # might start in a middle of a repeat			
			'session' 	  => Slim::Networking::Async::HTTP->new( ),
			'baseURL'     => $params->{baseURL}, 
	};		
	
	${*$self}{'song'} = $args->{'song'};
	${*$self}{'vars'} = $vars;
	Plugins::LCI::m4a::setEsds($vars->{context}, $params->{samplingRate}, $params->{channels});
		
	$log->debug("vars ", Data::Dump::dump(${*$self}{'vars'}));

	return $self;
}

sub onStop {
    my ($class, $song) = @_;
	my $elapsed = $song->master->controller->playingSongElapsed;
	my $id = getLink($song->track->url);
	
	if ($elapsed < $song->duration - 15) {
		$cache->set("lci:lastpos-$id", int ($elapsed), '30days');
		$log->info("Last position for $id is $elapsed");
	} else {
		$cache->remove("lci:lastpos-$id");
	}	
}

sub contentType { 'aac' }
sub isAudio { 1 }
sub isRemote { 1 }
sub songBytes { }
sub canSeek { 1 }
	
sub formatOverride {
	my $class = shift;
	my $song = shift;

	return $song->pluginData('format') || 'aac';
}

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;

	return { timeOffset => $newtime };
}

sub sysread {
	my $self  = $_[0];
	my $v = ${*{$self}}{'vars'};

	# waiting to get next chunk, nothing so far	
	if ( $v->{'fetching'} ) {
		$! = EINTR;
		return undef;
	}
	
	# end of current segment, get next one
	if ( !defined $v->{'inBuf'} || length ${$v->{'inBuf'}} == 0 ) {
	
		my $song = ${*${$_[0]}}{song};
		my $segments = $song->pluginData('segments');
		my $params = $song->pluginData('params');
		my $total = $segments ? scalar @{$segments} : int($params->{duration} / ($params->{d} / $params->{timescale})); 

		# end of stream
		return 0 if $v->{index} >= $total || !$v->{retry};
		
		$v->{fetching} = 1;	
		
		# get next fragment/chunk
		my $item = $segments ? @{$segments}[$v->{index}] : { d => $params->{duration} };
		my $suffix = $item->{media} || $params->{media};		

		# don't think that 't' can be set at anytime, but just in case...
		$v->{offset} = $item->{t} if $item->{t};
		
		# probably need some formatting for Number & Time
		$suffix =~ s/\$RepresentationID\$/$params->{representation}->{id}/;
		$suffix =~ s/\$Bandwidth\$/$params->{representation}->{bandwidth}/;
		$suffix =~ s/\$Time\$/$v->{offset}/;
		my $number = $v->{index} + 1;
		$suffix =~ s/\$Number\$/$number/;

		my $url = $v->{'baseURL'} . "/$suffix";
		
		my $request = HTTP::Request->new( GET => $url );
		$request->header( 'Connection', 'keep-alive' );
		$request->protocol( 'HTTP/1.1' );
		
		$log->info("fetching index:$v->{'index'}/$total url:$url");		

		$v->{'session'}->send_request( {
				request => $request,
				onRedirect => sub {
					my $request = shift;
					my $redirect = $request->uri;
					my $match = (reverse ($suffix) ^ reverse ($redirect)) =~ /^(\x00*)/;
					$v->{'baseURL'} = substr $redirect, 0, -$+[1] if $match;
					$log->info("being redirected from $url to ", $request->uri, "using new base $v->{'baseURL'}");
				},
				onBody => sub {
					$v->{fetching} = 0;
					$v->{offset} += $item->{d};
					$v->{repeat}++;	
					$v->{retry} = 5;
				
					if ($v->{repeat} > ($item->{r} || 0)) {
						$v->{index}++;
						$v->{repeat} = 0;
					}
					
					$v->{inBuf} = \shift->response->content;
					$log->debug("got chunk length: ", length ${$v->{'inBuf'}});
				},
				onError => sub {
					$v->{'session'}->disconnect;
					$v->{'fetching'} = 0;					
					$v->{'retry'} = $v->{index} < $total - 1 ? $v->{'retry'} - 1 : 0;
					$v->{'baseURL'} = $params->{'baseURL'};
					$log->error("cannot open session for $url ($_[1]) moving back to base URL");					
				},
		} );
		
		$! = EINTR;
		return undef;
	}	

	my $len = Plugins::LCI::m4a::getAudio($v->{'inBuf'}, $v->{'context'}, $_[1], $_[2]);
	return $len if $len;
	
	$! = EINTR;
	return undef;
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $url 	 = $song->track()->url;
	my $client   = $song->master();

	$song->pluginData(lastpos => ($url =~ /&lastpos=([\d]+)/)[0] || 0);
	$url =~ s/&lastpos=[\d]*//;					
	
	my $link = Plugins::LCI::API::API_URL . '/pages' . getLink($url);
	
	$log->info("getNextTrack : $url (link: $link)");
	
	if (!$link) {
		$errorCb->();
		return;
	}	
	
	my ($step1, $step2, $step3);
	my ($duration, $format, $root, $id);
		
	# get the stream_id
	$step1 = sub {
		my $data = shift->content;	
		eval { $data = decode_json($data) };
		#$log->debug("step 1 ", Data::Dump::dump($data));

		$errorCb->() unless $data->{page};
		
		$id = $data->{page}->{video}->{id};
		$log->info("Got stream id $id");
	
		# get the token's url (the is will give the mpd's url)
		my $http = Slim::Networking::SimpleAsyncHTTP->new ( $step2, $errorCb );
		$http->get( "http://mediainfo.tf1.fr/mediainfocombo/$id", 'User-Agent' => MPD_UA );  
	};
	
	# get the stream video link from stream_id (we have chosen MPD)
	$step2 = sub {
		my $data = shift->content;	
		eval { $data = decode_json($data) };
		#$log->debug("step 2 ", Data::Dump::dump($data));

		$errorCb->() unless $data->{delivery};
	
		$root = $data->{delivery}->{url};
		$format = $data->{delivery}->{format};
		$log->info("Got format $format for $root");
		
		# need to intercept the redirected url to determine true base (RFC3986)
		my $http = Slim::Networking::Async::HTTP->new;
		
		$http->send_request( {
			request => HTTP::Request->new( GET => $root ),
			onBody	=> $step3,
			# TODO: verify that $root is not captured (closure)
			onRedirect => sub {	
				$root = shift->uri =~ s/[^\/]+$//r;
				$root =~ s/\/$//;
			},
		} );		
	};
	
	# process the MPD
	$step3 = sub {
		my $mpd = shift->response->content;	
		#my $mpd = shift->content;	
		$log->info("processing mpd format");
		$log->debug($mpd);
		
		eval { $mpd = XMLin( $mpd, KeyAttr => [], ForceContent => 1, ForceArray => [ 'AdaptationSet', 'Representation', 'Period' ] ) };
		return $errorCb->() if $@;
		
		my ($adaptation, $representation);
		foreach my $item (@{$mpd->{Period}[0]->{AdaptationSet}}) { 
			if ($item->{mimeType} eq 'audio/mp4') {
				$adaptation = $item;
				my @bandwidth = sort { $a->{bandwidth} < $b->{bandwidth} } @{$item->{Representation}};
				$representation = $bandwidth[0];
				last;
			}	
		}	

		return $errorCb->() unless $representation;
	
		my $baseURL = getValue(['BaseURL', 'content'], [$mpd, $mpd->{Period}[0], $adaptation, $representation], '.');
		$baseURL = "$root/$baseURL" unless $baseURL =~ /^https?:/i;
		$baseURL =~ s/\/$//;
		
		my $duration = getValue('duration', [$representation, $adaptation, $mpd->{Period}[0], $mpd]);
		my ($misc, $hour, $min, $sec) = $duration =~ /P(?:([^T]*))T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/;
		$duration = ($sec || 0) + (($min || 0) * 60) + (($hour || 0) * 3600);

		# set of useful parameters for the $song object
		my $segments = $adaptation->{SegmentList}->{SegmentURL} || $adaptation->{SegmentTemplate}->{SegmentTimeline}->{S};
		my $params = {
			samplingRate => getValue('audioSamplingRate', [$representation, $adaptation]),
			channels => getValue('AudioChannelConfiguration', [$representation, $adaptation])->{value},
			duration => $duration,
			representation => $representation,
			media => $adaptation->{SegmentTemplate}->{media},
			d => $adaptation->{SegmentTemplate}->{duration},
			timescale => getValue('timescale', [$adaptation->{SegmentList}, $adaptation->{SegmentTemplate}]),
			baseURL => $baseURL,
			source => 'mpd',
		};
		
		$log->info("MPD parameters for baseURI $root\n", Data::Dump::dump($params));
				
		$song->pluginData(segments => $segments);
		$song->pluginData(params => $params);	
		
		$song->track->secs( $duration );
		$song->track->samplerate( $params->{samplingRate} );
		$song->track->channels( $params->{channels} ); 
		#$song->track->bitrate(  );
		
		if ( my $meta = $cache->get("lci:meta-$url") ) {
			$meta->{duration} = $duration;
			$meta->{type} = "aac\@$params->{samplingRate}Hz";
			$cache->set("lci:meta-$url", $meta);
		}	
		
		$client->currentPlaylistUpdateTime( Time::HiRes::time() );
		Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
		
		# ready to start
		$successCb->();
	};
	
	# start the sequence of requests and callbacks by getting episode details
	my $http = Slim::Networking::SimpleAsyncHTTP->new ( $step1, $errorCb );
	$http->get( $link );  
}	

sub getMetadataFor {
	my ($class, $client, $url) = @_;
	
	main::DEBUGLOG && $log->debug("getmetadata: $url");
	
	$url = getLink($url);
	my $meta = $cache->get("lci:meta-$url");
			
	if ( $meta && defined $meta->{duration} ) {
					
		Plugins::LCI::Plugin->updateRecentlyPlayed({
			url   => $url, 
			name  => $meta->{title}, 
			icon  => $meta->{icon},
		});

		main::DEBUGLOG && $log->debug("cache hit: $url");
		
		return $meta;
	} 

	my $page = '/pages' . $url;
			
	Plugins::LCI::API::search( $page, sub {
		my $data = shift->{page};

		$data = first { $_->{key} eq 'main' } @{$data->{data}};
		$data = first { $_->{key} eq 'body-header' } @{$data->{data}};
		$data = first { $_->{key} eq 'article-header-video' } @{$data->{data}};
		$data = $data->{data};
			
		my $image = Plugins::LCI::Plugin::getImageMin( $data->{pictures}->{elementList} ) if $prefs->get('icons');
		
		$meta->{title} = $data->{title} || '';
		$meta->{icon} = $meta->{cover} = $image || Plugins::LCI::Plugin::getIcon();
		$meta->{duration} = $data->{video}->{duration};
		$meta->{type} = 'LCI';

		$cache->set("lci:meta-$url", $meta);
		
		if ($client) {
			$client->currentPlaylistUpdateTime( Time::HiRes::time() );
			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
		}	
		
	} );		
		
	return { type	=> 'LCI',
			   title	=> "LCI",
			   icon     => Plugins::LCI::Plugin::getIcon(),
			   cover    => Plugins::LCI::Plugin::getIcon(),
			};
}	

	
sub getLink {
	my ($url) = @_;

	if ($url =~ m|lci:([^&]+)|) {
		return $1;
	}
		
	return undef;
}

sub getValue {
	my ($keys, $where, $mode) = @_;
	my $value;
	
	$keys = [$keys] unless ref $keys eq 'ARRAY';
	
	foreach my $hash (@$where) {
		foreach my $k (@$keys) {
			$hash = $hash->{$k};
			last unless $hash;
		}	
		next unless $hash;
		if ($mode eq '.') {
			$value .= $hash;
		} elsif ($mode eq 'f') {
			return $hash if $hash;
		} else {
			$value ||= $hash;
		}	
	}

	return $value;
}


1;
