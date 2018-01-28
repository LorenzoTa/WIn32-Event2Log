package Win32::Event2Log;

use 5.006;
use strict;
use warnings;
use Win32::EventLog;
use Carp;
use Storable;
use Data::Dumper;

our $VERSION = 27;



sub new {
      my $class = shift;
	  my %arg = @_; 
	  my %opt;
	  $opt{interval} 	 = $arg{interval} || 5;
	  $opt{computer} 	 = $arg{computer} ||  $ENV{COMPUTERNAME};
	  $opt{endtime}  	 = $arg{endtime}  ||  0;
	  $opt{verbosity}	 = $arg{verbosity}  ||  ($opt{mainlog} ? 1 : 0);
	  if ( $arg{mainlog} ){
			if ( $arg{verbosity} ){
				$opt{mainlog} = $arg{mainlog};
			}
			else{ $opt{mainlog} = undef}
	  }
	  else{
			if ($arg{verbosity}){
				$opt{mainlog} = './'.(caller())[1].'-history.log';
			}
	  }
	  $opt{lastreadfile} = $arg{lastreadfile}  ||  './'.(caller())[1].'-lastread.log';
	  return bless {
					interval 	=> $opt{interval}, 
					computer 	=> $opt{computer},
					endtime	 	=> $opt{endtime},
					verbosity	=> $opt{verbosity},
					mainlog 	=> $opt{mainlog},
					lastreadfile=> $opt{lastreadfile},
					rules 	 	=> {} }, $class;
}

sub add_rule{
	my $self = shift;
	my @arg = @_;
	my $ret;
	unless ($ret = $self->check_rule_arg(@arg)){
		carp "Failed during rule arguments check! received: -->@arg<--" ;
		return 0;
	}
	my $registry = $$ret{registry};
	delete $$ret{registry};
	push @{$self->{rules}->{$registry}}, $ret ;
	$self->{$registry.'_last'} = 0;
	return 1;
}
  
sub check_rule_arg {
	my $self= shift;
	my @arg = @_;
	return 0 unless @arg;
	my %arg = @arg;
	# check mandatory arguments
	# the registry to open
	unless (exists $arg{registry}){
		carp "No registry specified for the rule (must be 'System', 'Application', 'Security')";
		return 0;
	}
	unless ( $arg{registry} =~ /System|Application|Security|Installation/){
		carp "wrong or no registry specified for the rule (must be 'System', 'Application', 'Security', 'Installation')";
		return 0;
	}
	# the source of the event
	unless (exists $arg{source}){
		carp "No source specified for the rule (must be a valid source or a regex)";
		return 0;
	}
	# the destination log to be write
	unless (exists $arg{log}){
		carp "No logfile destination specified for the rule";
		return 0;
	}
	# check or set arguments
	# transform the source eventual string into a regex
	if ($arg{source}){
		unless (ref $arg{source} eq 'Regex'){
				my $regex;
				eval { $regex = qr/$arg{source}/ };
				if ($@){
					carp "source -->$arg{source}<-- does not compile succesfully";
					return 0;
				}
				else {$arg{source} = $regex}
		}
	}
	# the regex used to match the event message
	if ($arg{regex}){
		unless (ref $arg{regex} eq 'Regex'){
				my $regex;
				eval { $regex = qr/$arg{regex}/ };
				if ($@){
					carp "regex -->$arg{regex}<-- does not compile succesfully";
					return 0;
				}
				else {$arg{regex} = $regex}
		}
	}
	else { $arg{regex} = qr/./ }
	# the event type tranformed into a regex
	if ($arg{eventtype}){
		unless (ref $arg{eventtype} eq 'Regex'){
			$arg{eventtype} = eventtype_to_num($arg{eventtype});
			my $regex;
				eval { $regex = qr/$arg{eventtype}/ };
				if ($@){
					carp "regex for eventype -->$arg{eventtype}<-- does not compile succesfully";
					return 0;
				}
				else {$arg{eventtype} = $regex}	
		}
	}
	else { $arg{eventtype} = qr/^1|2|4|8|10$/}
	# the callback used to format the output
	if ($arg{format}){
		carp "format must be a code reference" unless ref $arg{format} eq 'CODE';
	}
	else {
		$arg{format} = sub{
							my $ev = shift;
							if (defined $ev->{Message} ){
								$ev->{Message} =~ s/\n/ /g;
							}
							else{$ev->{Message} = '-no message defined-'}
							return  scalar localtime($ev->{TimeGenerated})."\t".
									$ev->{Source}."\t".
									num_to_eventtype($ev->{EventType})."\t".
									#encode('CP-850',$ev->{Message})."\n";
									$ev->{Message}."\n";
		};
	}
	# the name of the rule
	unless ( $arg{name} ){ $arg{name} = $arg{registry}.'_rule_'.
											( 	
												$self->{rules}->{ $arg{registry} } 		?
												@{$self->{rules}->{ $arg{registry} }}	:
												0
											); }
	# all test passed
	return \%arg;
}

sub start{
	my $self = shift;
	unless (scalar keys %{$self->{rules}} > 0){
		print "no rules defined, so nothing to do. quitting..\n";
		return;
	}
	my $verbosity = \$self->{verbosity};
	print 	scalar(localtime(time))," ",
			+(join ' line ',(caller())[1..2])," started the engine (",
			__PACKAGE__," v. ",$Win32::Event2Log::VERSION,")\n"
			if  $$verbosity > 0;
	if ($self->{mainlog}){
		if (open my $logfh, '>>', $self->{mainlog}){
			print "all output redirected to ",$self->{mainlog},"\n" if $$verbosity > 0;
			select $logfh;
		}		
		else {
				print "WARNING unable to open ",$self->{mainlog},
						" in appending mode! using STDOUT";
		}
	}
	if (-e $self->{lastreadfile}){
		print "last numbers of each event registry parsed retrieved and stored to ",
				$self->{lastreadfile},"\n" if $$verbosity > 0;
		my $conf;
		eval {$conf = retrieve ($self->{lastreadfile})};
		if ($@){
				print "WARNING no configuration of last read events in ",
						$self->{lastreadfile},"\n";
		}
		else {
			foreach my $k(keys %$conf){
				$self->{$k} = $$conf{$k};
				print "imported $k = ",$self->{$k}," from ",
						$self->{lastreadfile},"\n" if $$verbosity > 0;				
			}
		}
	}
	$self->show_conf if $$verbosity > 0;
	# engine run lop
	while (1){
		if ( $self->{endtime} and time > $self->{endtime} ){
			print scalar(localtime(time))," endtime reached: (set at ",
					scalar(localtime($self->{endtime})),")\n" if $$verbosity > 0;
			# write each time the last numbers to storable file:
			$self->write_last_numbers();
			if ($self->{mainlog}){
				# this will prevent the lock on the mainlog file
				select STDOUT;
			}
			print "quitting..\n" if $$verbosity > 0;
			last;
		}
		# foreach registry
		foreach my $reg (keys %{$self->{rules}}){
			my $lastread = \$self->{$reg.'_last'};
			#####
			my $handle=Win32::EventLog->new($reg, $self->{computer}) or die "Can't open $reg EventLog\n";
			# get message automatically populateed
			$Win32::EventLog::GetMessageText = 1;
			my $recs; # total number of records
			$handle->GetNumber($recs) or die "Can't get number of EventLog records\n";
			my $base; # starting from
			$handle->GetOldest($base) or die "Can't get number of oldest EventLog record\n";
			if ( $recs == $$lastread ){
				print scalar(localtime(time))," no new events to read from $reg\n" if $$verbosity > 0;
				next; # go to next registry
			}
			else{
					print 	scalar(localtime(time))," working on the $reg registry reading from event number ",
							$$lastread + $base," (with base $base)\n" if $$verbosity > 0;
			}
			# see https://msdn.microsoft.com/en-us/library/windows/desktop/aa363646(v=vs.85).aspx 
			# for event datastructure description
			my $evnt;
			# number of records read
			my $read = 0;
			while ($$lastread < $recs + $base - 1 ) {
					# as per https://msdn.microsoft.com/it-it/library/windows/desktop/aa363674(v=vs.85).aspx
					$handle->Read(	EVENTLOG_BACKWARDS_READ|EVENTLOG_SEEK_READ, 
									$read+$base,   # offset
									$evnt )      		# the hashref populeted
							or die "Can't read EventLog entry ".($read+$base)."\n";
					# rule matching
					foreach my $rule (@{$self->{rules}->{$reg}}){
						if ( 	$evnt->{Source} =~ $rule->{source} and
								($evnt->{Message} and $evnt->{Message}=~ $rule->{regex})  and
								$evnt->{EventType} =~ $rule->{eventtype}
							) 
						{	
							open my $fh, '>>',$rule->{log} or die "unable to append to $rule->{log}";
							print $fh $rule->{format}->($evnt);
							close $fh;
							print $rule->{name}," matched! wrote $reg event number ",
									$evnt->{RecordNumber}," to ",$rule->{log},"\n" 
									if $$verbosity > 1;
							print Dumper \$evnt if $$verbosity > 2;
						}						
					}
					# end of rule matching
					$read++;
					$$lastread = $evnt->{RecordNumber};
			}
		print "succesfully read $read events from $reg registry\n" if $$verbosity > 0;
		} # end of foreach registry
		# write each time the last numbers to storable file: 
		# you cannot tell if the program will be stopped for example dusring shutdown
		$self->write_last_numbers(); 
		sleep $self->{interval};
	} # end of while 1 loop
}

sub write_last_numbers{
	my $self = shift;
	my %tostore;
	foreach (keys %{$self->{rules}}){
		print "storing ".$_.'_last'." with value of ".
				$self->{$_.'_last'}."\n" if $self->{verbosity} > 2;
		$tostore{$_.'_last'} = $self->{$_.'_last'};
	}
	store \%tostore,$self->{lastreadfile};
}

sub show_conf{
	my $self = shift;
	$Data::Dumper::Deparse=1;
	print 	"\n",__PACKAGE__,' v. ',$Win32::Event2Log::VERSION,
			" engine configuration:\n\n",
			map{	
				"$_".(' ' x (18 - length $_)).
				(defined $$self{$_} ?
					( 	
						$_ eq 'endtime' ? 
						(scalar localtime ($$self{$_})).' ('.$$self{$_}.')' : 
						$$self{$_} 
					)	:
				'')."\n"			
			}
			grep{$_ ne 'rules'} sort keys %$self;
	foreach my $reg (sort keys %{$self->{rules}}){
			foreach my $rule ( @{$self->{rules}->{$reg}} ){
				print "\nrule  ",$rule->{name}," for the registry ".$reg.":\n\n";
				print 	map{"$_".(' ' x (14 - length $_)).$rule->{$_}."\n"			
						} grep {$_ ne 'format' and $_ ne 'name'} sort keys %$rule;
				print "format        ",(Dumper \$rule->{format}),"\n";
			}		
	}
}

sub eventtype_to_num{
	my $str = shift;
	$str =~ s/E|error/1/g;
	$str =~ s/W|warning/2/g;
	$str =~ s/I|information/4/g;
	$str =~ s/S|sucess\s|_A|audit/8/g;
	$str =~ s/F|failure\s|_A|audit/10/g;
	$str =~ s/\s+//g;
	return $str;
}
sub num_to_eventtype{
	my $type = shift;
	# see again https://msdn.microsoft.com/en-us/library/windows/desktop/aa363646(v=vs.85).aspx
	my %conv = (
		1 	=> 'Error',
		2 	=> 'Warning',
		4 	=> 'Information',
		8 	=> 'Success_Audit',
		10	=> 'Failure_Audit'
	);
	if (defined $conv{$type}){
		return $conv{$type};
	}
	else{ return $type }
}

1;

__DATA__

=head1 NAME

Win32::Event2Log

=cut

=head1 DESCRIPTION

This module uses L<Win32::EventLog> and parses windows events and write them to plain logfiles.
This module is rule based: a rule it's a minimal set of conditions to be met to write an entry to a logfile.
You must add valid rules before starting the engine.
Once started, the engine will check events every x seconds (specified using C<interval> argument)
and for every registry (System, Application, Security, Installation or a user defined one) that is requested
at least in one rule will check for an event's source specified and optionally for some text contained in the
event's description. If the rule it's succesfull then an entry it's wrote in the specified logfile.
A custom callback can transofrm the line to be wrote using the C<format> option.
The parser can optionally shutdown itself if C<endtime> it is specified.


=head1 SYNOPSIS
	
	use strict;
	use warnings;
	
	use Win32::Event2Log;

	my $engine = Win32::Event2Log->new(	
					# frequency of event read, defualt to 5
				interval => seconds,
					# default to $ENV{COMPUTERNAME}	
				computer => computer,
					# seconds since epoch when the parser will stops (default to 0 ie never)
				endtime => time,
					# the operation log defaults to undef but if verbosity > 0 it will
					# defaults to the calling program name with '-operations.log appended				
				mainlog => file	
					# from 0 to 3, defaults to 0
				verbosity=> number
					# the file used  to retrieve and store numbers of
					# of each registry last read event.
					# Defaults to the calling program name with '-lastread.log' appended				
				lastreadfile=> file		
	);

	$engine->add_rule (
				
					# mandatory arguments
					# one among valid events registry
				registry => 'System',
					# a valid source or a regex
				source	 => 'Kernel-General',
					# the destination log where events will be wrote
				log		 => 'c:\path\to\file.log', 
				
					# optional arguments 
					# deaults to name with the appriopriat registry and an incremental number
				name 	=> 'rule name',
					# to optionally search inside the Message of the event
				regex	=> qr/perl/i,
					# a callback to transform the output. See add_rule below for more details
				format	=> sub{..},     
					
	);

	# from now the engine will run forever unless endtime was specified
	$engine->start;
	
=head1 METHODS

=head2 new

This is the constructor of the engine. It can accept options and if not provided sets some default.
C<interval> it's the frequency expressed in seconds between two reads of events. 
It's merely implemented sleeping so if many events have to be written to many different logfiles 
the next event read can happen a bit later than C<interval>. It defaults to 5 seconds.

C<computer> specify which machine will be interrogated to read events. It is infact possible to
read events from remote systems for example in a domain environment. It defaults to the local
system as found in the environment variable C<$ENV{COMPUTERNAME}>

C<endtime> lets you to specify when the engine will stops. It defaults to 0 meaning forever.
If you set C< endtime =E<gt> time + 3600> the engine will run just an hour. If you want, for example, the
engine to stop at midnight it's up to you to specify seconds from the epoch of the next midnight.

The C<verbosity> option can vary from 0 (almost no output) to 3 (which will dump also events that match
a rule and many other things). It defaults to 0 as the engine is meant to be run as scheduled task or at
system startup. If C<mainlog> it is specified C<verbosity> will be automatically set to 1 if it was 0 meaning
you want some output in the logfile if you specified one.

In C<mainlog> file will be redirected all the engine output. If you do not specify a file and the C<verbosity>
it is greater than 0 the name of the calling program with C<-history.log> appended to it will be used and the
file will be in the current directory.

The C<lastreadfile> is where the engine will look to know which last event id, for every registry, was already
read in the past. If this file does not exist the engine will start reading events since the oldest one until
the more recent one. This file contains a record for every registry separately.
In this file the engine will write ids of last event read at every iteration to be sure that a shutdown of the 
system or a kill of the process will do not lead to incorrect behaviour of the engine on next run.
If no file name is specified the name of the calling program with C<-lastread.log> appended to it will be used
and the file will be in the current directory.



=head2 add_rule

This is the method to be used to add rules to the engine. Infact an engine without rules is unuseful at all.
If an event matches a rule it wil be written to the appropriate logfile,
A rule construction accept many arguments: C<registry source log> are mandatory, while other are optional.

C<registry> is the event registry (C<System> or C<Application> for example) where the rule is applied. This 
argument must be specified literraly with the correct case for the first character. Please note that, fortunately, if
your system has not the english locale internally the registry is always C<System> and not the localized format
shown in the graphical interface of the Event Viewer.

C<source> it is the event source that must match for the rule to be successful. C<source> accepts a string or a 
compiled regex passed as in C< qr/^kernel/i > for example. This lets you to have more sources matched by a single
rule and this is useful because many sources are related. Even if a string it is passed will be internally compiled
into a regex and as regex will be shown in the configuration.

C<log> is the filename where events that matched the rule will be written. Note that the same file can be used
in different rules if this make sense for you. Infact the file will be opened in append mode and closed everytime
an entry has to be added to it. This is inteded to prevent some buffering the operating system is known to apply 
sometimes if the file is left open. 

C<name> it is the optional name you want to assign to the rule. If you do not specify a name a default, progressive
name containing the registry too will be created for you.

C<eventtype> it's an option to filter types of event. Internally types are numerical fields with the following meanings:
C< 1 'Error', 2 'Warning', 4 'Information', 8 'Success_Audit', 10 'Failure_Audit'>
Anyway for your lazyness you can specify them as lowercase strings separated by C<|> or as a regex and then
internally will be transformed into a regex using numerical values.
So C< eventtype => 'error|warning'> is the same of C< eventtype => 'Error|Warning'> and of C< eventtype => qr/^1|2$/>

C<regex> it is an option to filter just events which message text match what you want. It can be passed as compiled regex
or as string but internally will be compiled as regex. It defaults to C< qr/./ >

An optional callback can be passed with the option C<format> and will be used to format the line written to the logfile.
In this callback the object representing the event will be received as first argument.
The callback must return a string to be written. So you can grab and transform each event fields at your will.
Note also that you can use the C<num_to_eventtype> function inside your callback to have back a meaningful string instead
of a bare number for the type of the event.
Events fields are: C<Computer User TimeGenerated Strings RecordNumber Data Timewritten Message EventID Source Category Length ClosingRecordNumber EventType>
or at least these are those exposed by L<Win32::EventLog> 
See L<https://msdn.microsoft.com/en-us/library/windows/desktop/aa363646(v=vs.85).aspx> for further informations.
The C<format> options defaults to the following code:

	sub{
		my $ev = shift;
		if (defined $ev->{Message} ){
			$ev->{Message} =~ s/\n/ /g;
		}
		else{$ev->{Message} = '-no message defined-'}
		return  scalar localtime($ev->{TimeGenerated})."\t".
				$ev->{Source}."\t".
				num_to_eventtype($ev->{EventType})."\t".
				$ev->{Message}."\n";
	};


=head2 start

This is the method to start the engine. It just fails if no rule is defined. It runs the engine forever or until a
C<endtime> was specified in the engine configuration.

=head2 show_conf

This method can be used to nicely dump the current engine configuration and all rules.
It is used internally to print the configuration before starting reading events if C<verbosity> is set to 1 or more.


=head1 AUTHOR

Lorenzo Taviani, C<< <lorenzo at cpan.org> >>

=head1 BUGS

The main support forum for this module is perlmonks.org 

Please report any bugs or feature requests to C<bug-win32-event2log at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Win32-Event2Log>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Win32::Event2Log


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Win32-Event2Log>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Win32-Event2Log>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Win32-Event2Log>

=item * Search CPAN

L<http://search.cpan.org/dist/Win32-Event2Log/>

=back


=head1 ACKNOWLEDGEMENTS

This module would be not pssible without the underlying L<Win32::EventLog> one so many thanks to Jan Dubois for his work.


=head1 LICENSE AND COPYRIGHT

Copyright 2018 Lorenzo Taviani.

This program is released under the following license: Perl


=cut


