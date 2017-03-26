package Plugins::LCI::MPEGTS;

use strict;

use Data::Dumper;

use Slim::Utils::Log;

# streaming states
use constant SYNCHRO     => 1;
use constant PIDPAT	     => 2;
use constant PIDPMT	     => 3;
use constant AUDIO	     => 4;

my $log   = logger('plugin.LCI');

# offset from the start of the packet payload 	
# 3 for table header, 5 for table syntax, 2 for PAT/PMT	
use constant TABLE_OFS 			=> 0;
use constant TABLE_SYNTAX_OFS 	=> TABLE_OFS + 3;
use constant TABLE_DATA_OFS 	=> TABLE_SYNTAX_OFS + 5;

# offset from the start of the packet payload 	
# 3 for table header, 5 for table syntax, 2 for PAT/PMT	
use constant TABLE_OFS 			=> 0;
use constant TABLE_SYNTAX_OFS 	=> TABLE_OFS + 3;
use constant TABLE_DATA_OFS 	=> TABLE_SYNTAX_OFS + 5;

sub processTS {
	use bytes;

	my ($v, $outBuf, $maxBytes) = @_;
	my $state = $v->{'state'};
	my $packet;
	
	$$outBuf = '';
	
	while ( length(${$v->{'inBuf'}}) - $v->{'pos'} >= 188 && length($$outBuf) <= $maxBytes - 188 ) {
		my $offset = 0;
	
		#find synchro			
		if ($state == SYNCHRO)	{
		
			if ( ${$v->{inBuf}} =~ m/.{$v->{'pos'}}(G.{187}G)/s ) {
				$v->{'pos'} = $-[1] + $v->{pos};
				$log->debug ("Synchro found at: $v->{'pos'}");
				$state = PIDPAT;
			} else { 
				$log->debug ("Synchro not found");
				last;
			}
			
		} 
		
		#get a packet
		$packet = substr ${$v->{'inBuf'}}, $v->{'pos'}, 188;
		$v->{'pos'} += 188;
										
		if (substr($packet, 0, 1) ne 'G') {
			$log->error("Synchro lost!");
			$state = SYNCHRO;
		}
		
		my $pid = decode_u16(substr $packet, 1, 2) & 0x1fff;
		#$log->info("pid: $pid");
		
		my $af_flags = decode_u8(substr($packet, 3, 1));
		my $ps_flags = decode_u16(substr($packet, 1, 2));
				
		# skip the adaptation field if any
		my $af_len = ($af_flags & 0x20) ? decode_u8(substr($packet, 4, 1)) + 1 : 0;
		$packet = substr($packet, 4 + $af_len);
		
		if ($state != AUDIO) {
			#skip the fill if any (only happens at the beginning of a packet)
			my $ps_len = ($ps_flags & 0x4000) ? decode_u8(substr($packet, 0, 1)) + 1 : 0;
			$packet = substr($packet, $ps_len);
		}	
														
		#find the PMT pid's 
		if ($state == PIDPAT && $pid == 0) {
			# 3 for table header, 5 for table syntax, 2 for PAT
			$v->{pidPMT} = decode_u16(substr($packet, TABLE_DATA_OFS + 2, 2)) & 0x1fff;
		
			$log->debug("found PAT, pidPMT: $v->{pidPMT}");
			$state = PIDPMT;
		}
	
		#find the ES pid's
		if ($state == PIDPMT && defined $v->{pidPMT} && $pid == $v->{pidPMT}) {
			my $streams;
			
			$streams = getPMT($packet);
			
			foreach my $stream (@{$streams}) {
				my $type = $stream->{type};
				
				if ($type == 0x03 || $type == 0x04) {
					$v->{stream} = { format => 'mp3', pid => $stream->{pid} } 
				} 
				
				if ($type == 0x0f) {
					$v->{stream} = { format => 'aac', pid => $stream->{pid} } 
				}	
			}
			
			$log->debug ("Stream selected:", Dumper($v->{stream}));
			$state = AUDIO unless !defined $v->{stream};
		}	
		
		#finally, we do audio
		if ($state == AUDIO && defined $v->{stream} && $pid == $v->{stream}->{pid}) {
			my $ofs = 0;
						
			if ($ps_flags & 0x4000) {
				my $hdr = decode_u8(substr($packet, 6, 1));
				# option header length 3 + length
				$ofs = 2 + 1 + decode_u8(substr($packet, 6 + 2, 1)) if ($hdr & 0x80);
				$ofs += 6;
			}
						
			$$outBuf .= substr($packet, $ofs) if ($af_flags & 0x10);
			
		}	
		
		$v->{state} = $state;
	}
	
	return length $$outBuf;
	
}

sub decode_u8  { unpack('C', $_[0]) }
sub decode_u16 { unpack('n', $_[0]) }
sub decode_u24 { unpack('N', ("\0" . $_[0]) ) }
sub decode_u32 { unpack('N', $_[0]) }

sub getPMT	{
	my $packet = shift;
	my $streams = [];
	my $table_len = decode_u16(substr($packet, TABLE_OFS + 1, 2)) & 0x3ff;
	my $info_len  = decode_u16(substr($packet, TABLE_DATA_OFS + 2, 2)) & 0x3ff;
	
	#starts now at ES data
	$packet = substr($packet, TABLE_DATA_OFS + 4 + $info_len);
		
	my $count = 0;
	# bytes_count: table_len, -9 for table syntax CRC, -4 for PMT, 
	while ($count < $table_len - 9 - 4 - $info_len) {
		my $type = decode_u8(substr($packet, $count, 1));
		my $pid = decode_u16(substr($packet, $count + 1, 2)) & 0x1fff;
		$count += 5 + decode_u16(substr($packet, $count + 3, 2)) & 0x3ff;
		push @$streams, { type => $type, pid => $pid};
	}
	
	return $streams;
}

1;
