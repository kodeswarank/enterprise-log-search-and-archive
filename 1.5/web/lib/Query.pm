package Query;
use Moose;
with 'MooseX::Traits';
with 'Utils';
with 'Fields';
with 'MooseX::Clone';
use Results;
use Time::HiRes;
use Data::Dumper;
use Search::QueryParser;
use Storable qw(dclone);
use Socket;
use Log::Log4perl::Level;
use Date::Manip;
use Try::Tiny;
use Ouch qw(:trytiny);;
use String::CRC32;

# Object for dealing with user queries

our $Default_limit = 100;
our $Tokenizer_regex = '[^A-Za-z0-9\\-\\.\\@\\_]';
our $Sql_tokenizer_regex = '[^-A-Za-z0-9\\.\\@\\_]';

# Required
has 'user' => (is => 'rw', isa => 'User', required => 1);

# Required with defaults
has 'meta_params' => (is => 'rw', isa => 'HashRef', required => 1, default => sub { {} });
has 'type' => (is => 'rw', isa => 'Str', required => 1, default => 'index');
has 'results' => (is => 'rw', isa => 'Results', required => 1);
has 'start_time' => (is => 'ro', isa => 'Num', required => 1, default => sub { Time::HiRes::time() });
has 'groupby' => (traits => [qw(Array)], is => 'rw', isa => 'ArrayRef', required => 1, default => sub { [] },
	handles => { has_groupby => 'count', all_groupbys => 'elements', add_groupby => 'push' });
has 'orderby' => (is => 'rw', isa => 'Str');
has 'orderby_dir' => (is => 'rw', isa => 'Str', required => 1, default => 'ASC');
has 'timeout' => (is => 'rw', isa => 'Int', required => 1, default => 0);
has 'cancelled' => (is => 'rw', isa => 'Bool', required => 1, default => 0);
has 'archive' => (is => 'rw', isa => 'Bool', required => 1, default => 0);
has 'livetail' => (is => 'rw', isa => 'Bool', required => 1, default => 0);
has 'datasources' => (traits => [qw(Hash)], is => 'rw', isa => 'HashRef', required => 1, default => sub { { sphinx => 1 } });
has 'analytics' => (is => 'rw', isa => 'Bool', required => 1, default => 0);
has 'system' => (is => 'rw', isa => 'Bool', required => 1, default => 0);
has 'batch' => (is => 'rw', isa => 'Bool', required => 1, default => 0, trigger => \&_set_batch);
has 'limit' => (is => 'rw', isa => 'Int', required => 1, default => $Default_limit);
has 'offset' => (is => 'rw', isa => 'Int', required => 1, default => 0);
has 'classes' => (is => 'rw', isa => 'HashRef' => required => 1, default => sub { return { map { $_ => {} } qw(given excluded distinct permitted partially_permitted groupby) } });
has 'start' => (is => 'rw', isa => 'Int', required => 1, default => 0);
has 'end' => (is => 'rw', isa => 'Int', required => 1, default => sub { time() });
has 'cutoff' => (is => 'rw', isa => 'Int', required => 1, default => 0);
has 'transforms' => (traits => [qw(Array)], is => 'rw', isa => 'ArrayRef', required => 1, default => sub { [] },
	handles => { has_transforms => 'count', all_transforms => 'elements', num_transforms => 'count' });
has 'connectors' => (traits => [qw(Array)], is => 'rw', isa => 'ArrayRef', required => 1, default => sub { [] },
	handles => { has_connectors => 'count', all_connectors => 'elements', num_connectors => 'count',
		connector_idx => 'get', add_connector => 'push' });
has 'connector_params' => (traits => [qw(Array)], is => 'rw', isa => 'ArrayRef', required => 1, default => sub { [] },
	handles => { has_connector_params => 'count', all_connector_params => 'elements', num_connector_params => 'count',
		connector_params_idx => 'get', add_connector_params => 'push' });
has 'terms' => (is => 'rw', isa => 'HashRef', required => 1, default => sub { {} });
has 'nodes' => (traits => [qw(Hash)], is => 'rw', isa => 'HashRef', required => 1, default => sub { { given => {}, excluded => {} } });
has 'hash' => (is => 'rw', isa => 'Str', required => 1, default => '');
has 'highlights' => (traits => [qw(Hash)], is => 'rw', isa => 'HashRef', required => 1, default => sub { {} });
has 'warnings' => (traits => [qw(Array)], is => 'rw', isa => 'ArrayRef', required => 1, default => sub { [] },
	handles => { 'has_warnings' => 'count', 'clear_warnings' => 'clear', 'all_warnings' => 'elements' });
has 'stats' => (traits => [qw(Hash)], is => 'rw', isa => 'HashRef', required => 1, default => sub { {} });
has 'timezone_difference' => (is => 'rw', isa => 'HashRef', required => 1, default => sub { { start => 0, end => 0 } });
has 'peer_requests' => (is => 'rw', isa => 'HashRef', required => 1, default => sub { {} });
has 'import_search_terms' => (traits => [qw(Array)], is => 'rw', isa => 'ArrayRef', required => 1, default => sub { [] },
	handles => { 'has_import_search_terms' => 'count', 'all_import_search_terms' => 'elements' });
has 'id_ranges' => (traits => [qw(Array)], is => 'rw', isa => 'ArrayRef', required => 1, default => sub { [] },
	handles => { 'has_id_ranges' => 'count', 'all_id_ranges' => 'elements' });
has 'query_term_count' => (is => 'rw', isa => 'Num', required => 1, default => 0);
has 'max_query_time' => (is => 'rw', isa => 'Int', required => 1, default => 0);
has 'program_translations' => (is => 'rw', isa => 'HashRef', required => 1, default => sub { {} });
has 'implicit_plus' => (is => 'rw', isa => 'Bool', required => 1, default => 1);
has 'use_sql_regex' => (is => 'rw', isa => 'Bool', required => 1, default => 0);
has 'original_timeout' => (is => 'rw', isa => 'Int', required => 1, default => 0);

# Optional
has 'query_string' => (is => 'rw', isa => 'Str');
has 'qid' => (is => 'rw', isa => 'Int');
has 'schedule_id' => (is => 'rw', isa => 'Int');
has 'raw_query' => (is => 'rw', isa => 'Str');
has 'comments' => (is => 'rw', isa => 'Str');
has 'time_taken' => (is => 'rw', isa => 'Num', trigger => \&_set_time_taken);
has 'batch_message' => (is => 'rw', isa => 'Str');
has 'node_info' => (is => 'rw', isa => 'HashRef');
#has 'import_groupby' => (is => 'rw', isa => 'Str');
has 'peer_label' => (is => 'rw', isa => 'Str');
has 'from_peer' => (is => 'rw', isa => 'Str');

sub BUILDARGS {
	my $class = shift;
	my %params = @_;
	
	if ($params{qid}){
		my ($query, $sth);
		$query = 'SELECT username, query FROM query_log t1 JOIN users t2 ON (t1.uid=t2.uid) WHERE qid=?';
		$sth = $params{db}->prepare($query);
		$sth->execute($params{qid});
		my $row = $sth->fetchrow_hashref;
		throw(404, 'Invalid qid ' . $params{qid}, { qid => $params{qid} }) unless $row;
		$params{q} = $row->{query};
		$params{user} = User->new(username => $row->{username}, conf => $params{conf});
	}
	if ($params{q}){
		# JSON-encoded query from web
		my $decode = $params{json}->decode($params{q});
		$params{query_string} = $decode->{query_string};
		$params{meta_params} = $decode->{query_meta_params};
		$params{raw_query} = delete $params{q};
	}
	elsif ($params{query_meta_params}){
		$params{meta_params} = delete $params{query_meta_params};
	}
	
	foreach my $property (qw(groupby timeout archive analytics datasources nobatch livetail)){
		if ($params{meta_params}->{$property}){
			$params{$property} = delete $params{meta_params}->{$property};
		}
	}
	
	$params{results} ||= new Results();
	
	if ($params{conf}->get('query_timeout')){
		$params{timeout} = sprintf("%d", ($params{conf}->get('query_timeout') * 1000));
		$params{max_query_time} = .9 * $params{timeout}; #90%
	}
	
	unless ($params{user}){
		$params{user} = new User(username => 'system', conf => $params{conf});
		$params{log}->info('Defaulting user to system');
		if ($params{permissions}){
			$params{user}->permissions(ref($params{permissions}) ? $params{permissions} : $params{json}->decode($params{permissions}));
			$params{log}->trace('Set permissions: ' . Dumper($params{user}->permissions));
		}
	}
	
	return \%params;
}
 
sub BUILD {
	my $self = shift;
	
	$self->log->debug('meta_params: ' . Dumper($self->meta_params));
	$self->log->debug('groupby: ' . Dumper($self->groupby));
	
	$self->resolve_field_permissions($self->user);
	
	my ($query, $sth);
	
	my $ret = { query_string => $self->query_string, query_meta_params => $self->meta_params };	
		
	# Is this a system-initiated query?
	if ($self->schedule_id){
		$self->system(1);
	}
	elsif (not $self->peer_label and $self->user->username eq 'system'){
		$self->system(1);
	}
	
	unless (defined $self->query_string){
		# We may just be constructing this query as scaffolding for other things
		return $self;
	}
	
	unless ($self->node_info){
		$self->node_info($self->_get_node_info());
	}	
		
	# Set known values here
	if ($self->meta_params->{archive}){
		$self->archive(1);
	}
	if ($self->meta_params->{livetail}){
		$self->livetail(1);
	}
	
	# Override defaults for whether query terms are OR by default instead of AND by default
	if ($self->conf->get('default_or')){
		$self->implicit_plus(0);
	}
	
	# Set a defaults if available in preferences
	if ($self->user->preferences and $self->user->preferences->{tree}->{default_settings} and
		$self->user->preferences->{tree}){
		my $prefs = $self->user->preferences->{tree}->{default_settings};
		if ($prefs->{orderby_dir}){
			$self->orderby_dir($prefs->{orderby_dir});
			$self->orderby('timestamp');
		}
		if ($prefs->{timeout}){
			$self->timeout($prefs->{timeout});
		}
		if ($prefs->{default_or}){
			$self->implicit_plus(0);
		}
	}
		
	# Parse first to see if limit gets set which could incidate a batch job
	$self->_parse_query();
	
	$self->log->trace("Using timeout of " . $self->timeout);
	
	if ($self->has_groupby){
		$self->results( new Results::Groupby() );
	}
	
	if ($self->qid){
		$self->resolve_field_permissions($self->user); # finish this up from BUILDARGS now that we're blessed
		# Verify that this user owns this qid
		$query = 'SELECT qid FROM query_log WHERE qid=? AND uid=?';
		$sth = $self->db->prepare($query);
		$sth->execute($self->qid, $self->user->uid);
		my $row = $sth->fetchrow_hashref;
		throw(403, 'User is not authorized for this qid', { user => $self->user->username }) unless $row;
		$self->log->level($ERROR) unless $self->conf->get('debug_all');
	}
	else {
		# Log the query
		$self->db->begin_work;
		$query = 'INSERT INTO query_log (uid, query, system, archive) VALUES (?, ?, ?, ?)';
		$sth = $self->db->prepare($query);
		$sth->execute( $self->user->uid, $self->raw_query ? $self->raw_query : $self->json->encode({ query_string => $self->query_string, query_meta_params => $self->meta_params }), 
			$self->system, 0 ); # set batch later
		$query = 'SELECT MAX(qid) AS qid FROM query_log';
		$sth   = $self->db->prepare($query);
		$sth->execute();
		my $row = $sth->fetchrow_hashref;
		$self->db->commit;
		
		$self->qid($row->{qid});

		$self->log->debug( "Received query with qid " . $self->qid . " at " . time() );
	}
	
	$self->hash($self->_get_hash($self->qid));
	
	# Find highlights to inform the web client
	foreach my $boolean (qw(and or)){
		foreach my $op (keys %{ $self->terms->{attr_terms}->{$boolean} }){
			foreach my $field_name (keys %{ $self->terms->{attr_terms}->{$boolean}->{$op} }){
				foreach my $class_id (keys %{ $self->terms->{attr_terms}->{$boolean}->{$op}->{$field_name} }){
					foreach my $attr (keys %{ $self->terms->{attr_terms}->{$boolean}->{$op}->{$field_name}->{$class_id} }){
						foreach my $term (@{ $self->terms->{attr_terms}->{$boolean}->{$op}->{$field_name}->{$class_id}->{$attr} }){
							my @regex = _term_to_regex($term, $field_name);
							foreach (@regex){
								$self->highlights->{$_} = 1 if defined $_;
							}
						}
					}
				}
			}
		}
		foreach my $class_id (keys %{ $self->terms->{field_terms}->{$boolean} }){
			foreach my $field_name (keys %{ $self->terms->{field_terms}->{$boolean}->{$class_id} }){
				foreach my $term (@{ $self->terms->{field_terms}->{$boolean}->{$class_id}->{$field_name} }){
					my @regex = _term_to_regex($term, $field_name);
					foreach (@regex){
						$self->highlights->{$_} = 1 if defined $_;
					}
				}
			}
		}
		foreach my $term (sort keys %{ $self->terms->{any_field_terms}->{$boolean} }, sort keys %{ $self->terms->{any_field_terms_sql}->{$boolean} }){
			my @regex = _term_to_regex($term);
			foreach (@regex){
				$self->highlights->{$_} = 1 if defined $_;
			}
		}
	}
	
	$self->stats->{get_node_info} = $self->node_info->{took};
		
	return $self;	
}

sub add_warning {
	my $self = shift;
	my $code = shift;
	my $errstr = shift;
	my $data = shift;
	
	push @{ $self->warnings }, new Ouch($code, $errstr, $data);
}

sub _term_to_regex {
	my $term = shift;
	my $field_name = shift;
	my $regex = $term;
	return if $field_name and $field_name eq 'class'; # we dont' want to highlight class integers
	if (my @m = $regex =~ /^\(+ (\@\w+)\ ([^|]+)? (?:[\|\s]? ([^\)]+))* \)+$/x){
		if ($m[0] eq '@class'){
			return; # we dont' want to highlight class integers
		}
		else {
			my @ret = @m[1..$#m];# don't return the field name
			foreach (@ret){
				$_ = '(?:^|' . $Tokenizer_regex . ')(' . $_ . ')(?:' . $Tokenizer_regex . '|$)';
			}
			return  @ret;
		}
	}
	elsif (@m = $regex =~ /^\( ([^|]+)? (?:[\|\s]? ([^\)]+))* \)+$/x){
		foreach (@m){
			$_ = '(?:^|' . $Tokenizer_regex . ')(' . $_ . ')(?:' . $Tokenizer_regex . '|$)';
		}
		return @m;
	}
	$regex =~ s/^\s{2,}/\ /;
	$regex =~ s/\s{2,}$/\ /;
	$regex =~ s/\s/\./g;
	$regex =~ s/\\{2,}/\\/g;
	$regex =~ s/[^a-zA-Z0-9\.\_\-\@]//g;
	$regex = '(?:^|' . $Tokenizer_regex . ')(' . $regex . ')(?:' . $Tokenizer_regex . '|$)';
	return ($regex);
}

sub term_to_sql_term {
	my $self = shift;
	my $term = shift;
	my $field_name = shift;
	my $regex = $term;
	return if $field_name and $field_name eq 'class'; # we dont' want to highlight class integers
	if (my @m = $regex =~ /^\(+ (\@\w+)\ ([^|]+)? (?:[\|\s]? ([^\)]+))* \)+$/x){
		if ($m[0] eq '@class'){
			return; # we dont' want to search this
		}
		else {
			my @ret = @m[1..$#m];# don't return the field name
			foreach (@ret){
				$_ = '(^|' . $Sql_tokenizer_regex . ')(' . $_ . ')(' . $Sql_tokenizer_regex . '|$)';
			}
			return $ret[0];
		}
	}
	elsif (@m = $regex =~ /^\( ([^|]+)? (?:[\|\s]? ([^\)]+))* \)+$/x){
		foreach (@m){
			$_ = '(^|' . $Sql_tokenizer_regex . ')(' . $_ . ')(' . $Sql_tokenizer_regex . '|$)';
		}
		return $m[0];
	}
	$regex =~ s/^\s{2,}/\ /;
	$regex =~ s/\s{2,}$/\ /;
	$regex =~ s/\s/\./g;
	$regex =~ s/\\{2,}/\\/g;
	$regex =~ s/[^a-zA-Z0-9\.\_\-\@]//g;
	$regex = '(^|' . $Sql_tokenizer_regex . ')(' . $regex . ')(' . $Sql_tokenizer_regex . '|$)';
	return $regex;
}

sub TO_JSON {
	my $self = shift;
	my $ret = {
		qid => $self->qid,
		totalTime => $self->time_taken,
		results => $self->results->results, 
		totalRecords => $self->results->total_records, 
		recordsReturned => $self->results->records_returned,	
		groupby => $self->groupby,
		orderby_dir => $self->orderby_dir,
		query_string => $self->query_string,
		query_meta_params => $self->meta_params,
		hash => $self->hash,
		highlights => $self->highlights,
		stats => $self->stats,
		approximate => $self->results->is_approximate,
	};
	
	$ret->{query_meta_params}->{archive} = 1 if $self->archive;
	$ret->{query_meta_params}->{livetail} = 1 if $self->livetail;
	
	unless ($ret->{groupby} and ref($ret->{groupby}) and ref($ret->{groupby}) eq 'ARRAY' and scalar @{ $ret->{groupby} }){
		delete $ret->{groupby};
	}
	
	# Check to see if our result is bulky
	unless ($self->meta_params->{nobatch}){
		if ($self->results->is_bulk){
			$ret->{bulk_file} = $self->results->bulk_file;
			$ret->{batch_query} = $self->qid;
			my $link = sprintf('%sQuery/get_bulk_file?qid=%d', 
				$self->conf->get('email/base_url') ? $self->conf->get('email/base_url') : 'http://localhost/',
				$self->qid);
			$ret->{batch_message} = 'Results: <a target="_blank" href="' . $link . '">' . $link . '</a>';
		}
		elsif ($self->batch_message){
			$ret->{batch_message} = $self->batch_message;
		}
		
		if ($self->batch){
			$ret->{batch} = 1;
		}
	}
	
	if ($self->has_warnings){
		$ret->{warnings} = $self->warnings;
	}
	
	return $ret;
}

sub _set_batch {
	my ( $self, $new_val, $old_val ) = @_;
	my ($query, $sth);
	$query = 'UPDATE query_log SET archive=? WHERE qid=?';
	$sth = $self->db->prepare($query);
	$sth->execute($new_val, $self->qid);
	return $sth->rows;
}

sub _set_time_taken {
	my ( $self, $new_val, $old_val ) = @_;
	my ($query, $sth);
	
	# Update the db to ack
	$query = 'UPDATE query_log SET num_results=?, milliseconds=? '
	  		. 'WHERE qid=?';
	$sth = $self->db->prepare($query);
	$sth->execute( $self->results->records_returned, $new_val, $self->qid );
	
	return $sth->rows;
}

sub _parse_query_string {
	my $self = shift;
	my $raw_query = shift;
	my $effective_operator = shift;
	
	my $qp = new Search::QueryParser(rxTerm => qr/[^\s()]+/, rxField => qr/[\w,\.]+/);
	# Special case for a lone zero
	if ($raw_query eq '0'){
		$raw_query = '"0"';
	}
	my $orig_parsed_query = $qp->parse($raw_query, $self->implicit_plus) or throw(400, $qp->err, { query_string => $raw_query });
	$self->log->debug("orig_parsed_query: " . Dumper($orig_parsed_query));
	
	my $parsed_query = dclone($orig_parsed_query); #dclone so recursion doesn't mess up original
	
	# Override any operators with the given effective operator
	if ($effective_operator){
		foreach my $op (keys %$parsed_query){
			my $arr = delete $parsed_query->{$op}; 
			$parsed_query->{$effective_operator} ||= [];
			push @{ $parsed_query->{$effective_operator} }, @$arr;
		}
		$self->log->debug("$parsed_query: " . Dumper($parsed_query));
	}
	
	# Recursively parse the query terms
	$self->_parse_query_term($parsed_query);
}

sub timezone_diff {
	my $self = shift;
	my $time = shift;
	
	# Apply client's timezone settings
	if (defined $self->meta_params->{timezone_offset}){
		# Find our offset in minutes to match Javascript's offset designation
		
		# Account for time given in epoch format
		if ($time =~ /^\d{10}$/){
			$time = 'epoch ' . $time;
		}
		my $server_offset_then = int(UnixDate(ParseDate($time), '%z')) / 100 * -60;
		my $server_offset_now = int(UnixDate(ParseDate('now'), '%z')) / 100 * -60;
		if ($self->meta_params->{timezone_offset} and $server_offset_then != $server_offset_now){
			my $dst_diff = $server_offset_then - $server_offset_now;
			$self->log->trace('Applying daylight savings time difference of ' . $dst_diff);
			$self->meta_params->{timezone_offset} += $dst_diff;
		}
		my $tz_diff = (($self->meta_params->{timezone_offset} - $server_offset_then) * 60);
		$self->log->trace('Applying timezone offset for ' . $time . ' of ' . $tz_diff);
		return $tz_diff;
	}
}

sub _parse_query {
	my $self = shift;
	
	my $raw_query = $self->query_string;
	
	my $stopwords = $self->conf->get('stopwords');
		
	foreach my $class_id (sort keys %{ $self->user->permissions->{fields} }){
		$self->classes->{partially_permitted}->{$class_id} = 1;
	}
	$self->log->trace('partially_permitted_classes: ' . Dumper($self->classes->{partially_permitted}));
	
#	# Attach the query filters for this user from permissions
#	my $filtered_raw_query = $raw_query;
#	if ($self->user->permissions->{filter}){
#		$filtered_raw_query .= ' ' . $self->user->permissions->{filter};
#	}
	
	# Strip off any connectors and apply later
	($raw_query, my @connectors) = split(/\s*\>\s+/, $raw_query);
	my @connector_params;
	foreach my $raw_connector (@connectors){
		#TODO cleanup this regex crime against humanity below
		$raw_connector =~ /([^\(]+)\(?( [^()]*+ | (?0) )\)?$/x;
		$self->add_connector($1);
		$self->log->trace("Added connector $1");
		my $raw_params = $2;
		if ($raw_params){
			$raw_params =~ s/\)$//;
			my @masks = $raw_params =~ /([\w]+\( (?: [^()]*+ | (?0) ) \))/gx;
			my $clone = $raw_params;
			foreach my $mask (@masks){
				$clone =~ s/\Q$mask\E/__MASK__/;
			}
			my @connector_params = split(/\s*,\s*/, $clone);
			foreach my $mask (@masks){
				$connector_params[0] =~ s/__MASK__/$mask/;
			}
			$self->add_connector_params([@connector_params]);
			$self->log->trace("Added connector params " . Dumper(\@connector_params));
		}
		
#		$raw_connector =~ /([^\(]+)\(?([^\)]+)\)?/;
#		$self->add_connector($1);
#		$self->log->trace("Added connector $1");
#		my $raw_params = $2;
#		if ($raw_params){
#			$raw_params =~ /([^\,]+)\,?([^\,]+)\,?/;
#			$self->add_connector_params([split(/\s*,\s*/, $raw_params)]);
#			$self->log->trace("Added connector params $2");
#		}
	}
		
	# Strip off any transforms and apply later
	($raw_query, my @transforms) = split(/\s*\|\s+/, $raw_query);
	
	# Make sure that any lone lowercase 'or' terms are uppercase for DWIM behavior
	$raw_query =~ s/\sor\s/ OR /gi;
	
	$self->log->trace('query: ' . $raw_query . ', transforms: ' . join(' ', @transforms));
	$self->transforms([ @transforms ]);
	
	# See if there are any connectors given
	if ($self->meta_params->{connector}){
		my $connector = $self->meta_params->{connector};
		$self->add_connector($connector);
		$self->add_connector_params($self->meta_params->{connector_params});
	}
		
	# Check to see if the class was given in meta params
	if ($self->meta_params->{class}){
		$self->classes->{given}->{ sprintf("%d", $self->node_info->{classes}->{ uc($self->meta_params->{class}) }) } = 1;
	}
		
	# Check for meta limit
	if (exists $self->meta_params->{limit}){
		$self->limit(sprintf("%d", $self->meta_params->{limit}));
		$self->log->debug("Set limit " . $self->limit);
	}
	
	if ($self->meta_params->{start}){
		my $tz_diff = $self->timezone_diff($self->meta_params->{start});
		if ($self->meta_params->{start} =~ /^\d+(?:\.\d+)?$/){
			$self->start(int($self->meta_params->{start}));
		}
		else {
			$self->log->debug('Started with ' . $self->meta_params->{start} . ' which parses to ' . 
				UnixDate(ParseDate($self->meta_params->{start}), "%s"));
			#my $start = UnixDate(ParseDate($self->meta_params->{start}), "%s");
			my $start = UnixDate(ParseDate($self->meta_params->{start}), "%s") + $tz_diff;
			$self->log->debug('ended with ' . $start);
			$self->start($start);
			$self->meta_params->{start} = $start;
		}
	}
	if ($self->meta_params->{end}){
		my $tz_diff = $self->timezone_diff($self->meta_params->{end});
		if ($self->meta_params->{end} =~ /^\d+(?:\.\d+)?$/){
			$self->end(int($self->meta_params->{end}));
		}
		else {
			#my $end = UnixDate(ParseDate($self->meta_params->{end}), "%s");
			my $end = UnixDate(ParseDate($self->meta_params->{end}), "%s") + $tz_diff;
			$self->end($end);
			$self->meta_params->{end} = $end;
		}
	}
		
	foreach my $type (qw(field_terms attr_terms)){
		foreach my $boolean (qw(and or not)){
			$self->terms->{$type}->{$boolean} = {};
		}
	}
	foreach my $boolean (qw(and or not)){
		$self->terms->{any_field_terms}->{$boolean} = {};
		$self->terms->{any_field_terms_sql}->{$boolean} = {};
	}
	$self->terms->{distinct_fields} = {};
		
	if ($raw_query =~ /\S/){ # could be meta_attr-only
#		my $qp = new Search::QueryParser(rxTerm => qr/[^\s()]+/, rxField => qr/[\w,\.]+/);
#		my $orig_parsed_query = $qp->parse($raw_query, $Implicit_plus) or die($qp->err);
#		$self->log->debug("orig_parsed_query: " . Dumper($orig_parsed_query));
#		
#		my $parsed_query = dclone($orig_parsed_query); #dclone so recursion doesn't mess up original
#		
#		# Recursively parse the query terms
#		$self->_parse_query_term($parsed_query);
		$self->_parse_query_string($raw_query);
	}
	else {
		throw(400,'No query terms given', { query_string => '' });
	}
	
	# Check for blanket allow on classes
	if ($self->user->permissions->{class_id}->{0} or $self->user->is_admin){
		$self->log->trace('User has access to all classes');
		$self->classes->{permitted} = $self->node_info->{classes_by_id};
	}
	else {
		$self->classes->{permitted} = { %{ $self->user->permissions->{class_id} } };
		
		# Drop any query terms that wanted to use a forbidden class
		foreach my $boolean (qw(and or not range_and range_not range_or)){
			foreach my $op (keys %{ $self->terms->{attr_terms}->{$boolean} }){
				foreach my $field_name (keys %{ $self->terms->{attr_terms}->{$boolean}->{$op} }){
					foreach my $class_id (keys %{ $self->terms->{attr_terms}->{$boolean}->{$op}->{$field_name} }){
						next if $class_id eq 0 # this is handled specially below
							or $self->classes->{permitted}->{$class_id}
							or exists $self->classes->{partially_permitted}->{$class_id};
						my $forbidden = delete $self->terms->{attr_terms}->{$boolean}->{$op}->{$field_name}->{$class_id};
						$self->log->warn('Forbidding attr_term from class_id ' . $class_id . ' with ' . Dumper($forbidden));
						unless (scalar keys %{ $self->terms->{attr_terms}->{$boolean}->{$op}->{$field_name} }){
							throw(403, 'All terms for field ' . $field_name . ' were dropped due to insufficient permissions.', { term => $field_name });
						}
					}
				}
			}
			
			foreach my $class_id (keys %{ $self->terms->{field_terms}->{$boolean} }){
				next if $class_id eq 0 # this is handled specially below
					or $self->classes->{permitted}->{$class_id}
					or exists $self->classes->{partially_permitted}->{$class_id};
				my $forbidden = delete $self->terms->{field_terms}->{$boolean}->{$class_id};
				$self->log->warn('Forbidding field_term from class_id ' . $class_id . ' with ' . Dumper($forbidden));
				foreach my $attr (keys %{ $self->terms->{field_terms}->{$boolean}->{$class_id} } ){
					unless (scalar keys %{ $self->terms->{field_terms}->{$boolean}->{$class_id}->{$attr} }){
						throw(403, 'All terms for field ' . $attr . ' were dropped due to insufficient permissions.', { term => $attr });
					}
				}
			}
		}
	}
	
	# Adjust classes if necessary
	$self->log->trace('given_classes before adjustments: ' . Dumper($self->classes->{given}));
	$self->log->trace('distinct_classes before adjustments: ' . Dumper($self->classes->{distinct}));
	
	# Add on any class 0 fields
	foreach my $boolean (qw(and or not)){
		foreach my $class_id (keys %{ $self->terms->{field_terms}->{$boolean} }){
			$self->classes->{distinct}->{$class_id} = 1;
		}
	}
	foreach my $boolean (qw(and or not range_and range_not range_or)){
		foreach my $op (keys %{ $self->terms->{attr_terms}->{$boolean} }){
			foreach my $field_name (keys %{ $self->terms->{attr_terms}->{$boolean}->{$op} }){
				foreach my $class_id (keys %{ $self->terms->{attr_terms}->{$boolean}->{$op}->{$field_name} }){
					$self->classes->{distinct}->{$class_id} = 1;
				}
			}
		}
	}
	
	# Verify that all asked for classes are available in the groupby
	if (scalar keys %{ $self->classes->{given} } and scalar keys %{ $self->classes->{groupby} } ){
		foreach my $class_id (keys %{ $self->classes->{given} }){
			unless ($self->classes->{groupby}->{$class_id}){
				$self->log->trace('groupby class ' . $class_id . ' is a requested class_id');
			}
		}
	}
	# Otherwise we're just using the groupby classes
	elsif (scalar keys %{ $self->classes->{groupby} }){
		$self->classes->{given} = $self->classes->{groupby};
	}
		
	if (scalar keys %{ $self->classes->{given} } == 1 and $self->classes->{given}->{0}){
		$self->classes->{distinct} = $self->classes->{permitted};
		foreach my $class_id (keys %{ $self->classes->{partially_permitted} }){
			$self->classes->{distinct}->{$class_id} = 1;
		}
	}
	elsif (scalar keys %{ $self->classes->{given} }){ #if 0 (meaning any) is given, go with permitted classes
		$self->classes->{distinct} = $self->classes->{distinct}->{0} ? { 0 => 1 } : {}; # include class zero if necessary
		foreach my $key (keys %{ $self->classes->{given} }){
			if ($self->classes->{permitted}->{$key} or exists $self->classes->{partially_permitted}->{$key}){
				$self->classes->{distinct}->{$key} = 1;
			}
			else {
				$self->log->warn('Not allowed to query given class ' . $key);
			}
		}	
	}
	elsif (scalar keys %{ $self->classes->{distinct} }) {
		foreach my $key (keys %{ $self->classes->{distinct} }){
			unless ($self->classes->{permitted}->{$key} or exists $self->classes->{partially_permitted}->{$key}){
				delete $self->classes->{distinct}->{$key};
			}
		}
	}
	else {
		$self->classes->{distinct} = $self->classes->{permitted};
		foreach my $class_id (keys %{ $self->classes->{partially_permitted} }){
			$self->classes->{distinct}->{$class_id} = 1;
		}
	}
	
	if (scalar keys %{ $self->classes->{excluded} }){
		foreach my $class_id (keys %{ $self->classes->{excluded} }){
			$self->log->trace("Excluding class_id $class_id");
			delete $self->classes->{distinct}->{$class_id};
		}
	}
	$self->log->trace('distinct_classes after adjustments: ' . Dumper($self->classes->{distinct}));
	
	# If no class was given anywhere, see if we can divine it from a groupby
	if (not scalar keys %{ $self->classes->{given} }){
		if ($self->has_groupby){
			foreach my $field ($self->all_groupbys){
				# Special case for node
				next if $field eq 'node';
				my $field_infos = $self->get_field($field);
				$self->log->debug('groupby field_infos: ' . Dumper($field_infos));
				foreach my $class_id (keys %{$field_infos}){
					$self->classes->{given}->{$class_id} = 1;
				}
			}
		}
	}
	
	# Reduce the distinct classes if there are fields/attrs given in the AND clause
	foreach my $field_name (keys %{ $self->terms->{distinct_fields} }){
		my $field_infos = $self->get_field($field_name);
		foreach my $class_id (keys %{ $self->classes->{distinct} }){
			next unless $class_id;
			unless ($field_infos->{$class_id} or $field_infos->{0}){
				$self->log->trace('Class ' . $class_id . ' does not have field ' . $field_name);
				delete $self->classes->{distinct}->{$class_id};
			}
		}
	}
	unless (scalar keys %{ $self->classes->{distinct} }){
		throw(400, 'No event classes have all of these fields: ' . join(', ', sort keys %{ $self->terms->{distinct_fields} }), { query_string => $self->query_string });
	}
	
	$self->log->debug('attr before conversion: ' . Dumper($self->terms->{attr_terms}));
	
	# Remove any terms or attrs that aren't in distinct classes now
	foreach my $boolean (qw(and or not)){
		foreach my $class_id (keys %{ $self->terms->{field_terms}->{$boolean} }){
			unless ($self->classes->{distinct}->{$class_id}){
				delete $self->terms->{field_terms}->{$boolean}->{$class_id};
			}
		}
	}
	foreach my $boolean (qw(and or not range_and range_not range_or)){
		foreach my $op (keys %{ $self->terms->{attr_terms}->{$boolean} }){
			foreach my $field_name (keys %{ $self->terms->{attr_terms}->{$boolean}->{$op} }){
				foreach my $class_id (keys %{ $self->terms->{attr_terms}->{$boolean}->{$op}->{$field_name} }){
					unless ($self->classes->{distinct}->{$class_id}){
						delete $self->terms->{attr_terms}->{$boolean}->{$op}->{$field_name}->{$class_id};
					}
				}
			}
		}
	}
	
	$self->log->debug('attr_terms: ' . Dumper($self->terms->{attr_terms}));
	
	my $num_added_terms = 0;
	my $num_removed_terms = 0;
	
	# Adjust hosts/programs based on permissions
	foreach my $attr (qw(host_id program_id node_id)){
		# Do we have a blanket allow permission?
		if ($self->user->permissions->{$attr}->{0}){
			$self->log->debug('Permissions grant access to any ' . $attr);
			next;
		}
		else {
			# Need to only allow access to the whitelist in permissions
			
			# Add filters for the whitelisted items
			# If there are no exceptions to the whitelist, no query will succeed
			if (not scalar keys %{ $self->user->permissions->{$attr} }){
				throw(403, 'Insufficient privileges for querying any ' . $attr, { term => $attr }); 
			}
			
			# Remove items not explicitly whitelisted
			foreach my $boolean (qw(and or)){
				foreach my $op ('', '='){
					next unless $self->terms->{attr_terms}->{$boolean}
						and $self->terms->{attr_terms}->{$boolean}->{$op}
						and $self->terms->{attr_terms}->{$boolean}->{$op}->{0} 
						and $self->terms->{attr_terms}->{$boolean}->{$op}->{0}->{$attr};
					foreach my $id (keys %{ $self->terms->{attr_terms}->{$boolean}->{$op}->{0}->{$attr} }){
						unless($self->user->is_permitted($attr, $id)){
							throw(403, "Insufficient permissions to query $id from $attr", { term => $attr });
						}
					}
				}
			}
		}
	}
	
#	# Optimization: for the any-term fields, only search on the first term and use the rest as filters if the fields are int fields
#	foreach my $boolean (qw(and not)){
#		unless (scalar @{ $self->terms->{any_field_terms}->{$boolean} }){
#			$self->terms->{any_field_terms}->{$boolean} = {};
#			next;
#		}
#		my %deletion_candidates;
#		foreach my $op (keys %{ $self->terms->{attr_terms}->{$boolean} }){
#			foreach my $field_name (keys %{ $self->terms->{attr_terms}->{$boolean}->{$op} }){
#				foreach my $class_id (keys %{ $self->terms->{attr_terms}->{$boolean}->{$op}->{$field_name} }){
#					foreach my $attr (keys %{ $self->terms->{attr_terms}->{$boolean}->{$op}->{$field_name}->{$class_id} }){
#						foreach my $raw_value (@{ $self->terms->{attr_terms}->{$boolean}->{$op}->{$field_name}->{$class_id}->{$attr} }){
#							my $col = $attr;
#							$col =~ s/^attr\_//;
#							my $resolved_value = $self->resolve_value($class_id, $raw_value, $col);
#							$deletion_candidates{$resolved_value} = 1;
#						}
#					}
#				}
#			}
#		}
#	
#		my @keep = shift @{ $self->terms->{any_field_terms}->{$boolean} };
#		foreach my $term (@{ $self->terms->{any_field_terms}->{$boolean} }){
#			if ($deletion_candidates{$term}){
#				$self->log->trace('Optimizing out any-field term search for term ' . $term);
#			}
#			else {
#				push @keep, $term;
#			}
#		}
#		$self->terms->{any_field_terms}->{$boolean} = { map { $_ => 1 } @keep };
#	}
#	$self->terms->{any_field_terms}->{or} = { map { $_ => 1 } @{ $self->terms->{any_field_terms}->{or} } };
	
	# Check all field terms to see if they are a stopword and warn if necessary
	if ($stopwords and ref($stopwords) and ref($stopwords) eq 'HASH'){
		$self->log->debug('checking terms against ' . (scalar keys %$stopwords) . ' stopwords');
		foreach my $boolean (qw(and or not)){
			foreach my $class_id (keys %{ $self->terms->{field_terms}->{$boolean} }){
				foreach my $raw_field (keys %{ $self->terms->{field_terms}->{$boolean}->{$class_id} }){
					next unless $self->terms->{field_terms}->{$boolean}->{$class_id}->{$raw_field};
					for (my $i = 0; $i < (scalar @{ $self->terms->{field_terms}->{$boolean}->{$class_id}->{$raw_field} }); $i++){
						my $term = $self->terms->{field_terms}->{$boolean}->{$class_id}->{$raw_field}->[$i];
						if ($self->is_stopword($term)){
							my $err = 'Removed term ' . $term . ' which is too common';
							if ($boolean eq 'or' or $self->has_groupby){
								$self->add_warning(400, $err, { term => $term });
								$self->log->warn($err);
							}
							else {
								$self->log->trace($err);
							}
							$num_removed_terms++;
							
							my $field_info = $self->node_info->{fields_by_order}->{$class_id}->{ $Fields::Field_to_order->{$raw_field} };
							my $field_name = lc($field_info->{text});
							my $field_type = $field_info->{field_type};
							my $attr_name = $Fields::Field_order_to_attr->{ $Fields::Field_to_order->{$raw_field} };
							splice(@{ $self->terms->{field_terms}->{$boolean}->{$class_id}->{$raw_field} }, $i, 1);
							# Decrement $i because we removed an element from the array
							$i--;
							if ($field_type ne 'string'){
								my $normalized_term = $self->normalize_value($class_id, $term, $field_info->{field_order});
								unless (grep { $_ eq $normalized_term } @{ $self->terms->{attr_terms}->{$boolean}->{'='}->{$field_name}->{$class_id}->{$attr_name} }){
									push @{ $self->terms->{attr_terms}->{$boolean}->{'='}->{$field_name}->{$class_id}->{$attr_name} }, $normalized_term;
								}
							}
							else {
								# Temporarily store these terms in field_terms_sql so it's clear they don't count as a query term 
								#  for calculating whether to use Sphinx or not
								$self->terms->{field_terms_sql} ||= {};
								$self->terms->{field_terms_sql}->{$boolean} ||= {};
								$self->terms->{field_terms_sql}->{$boolean}->{$class_id} ||= {};
								$self->terms->{field_terms_sql}->{$boolean}->{$class_id}->{$raw_field} ||= [];
								push @{ $self->terms->{field_terms_sql}->{$boolean}->{$class_id}->{$raw_field} }, $term;
							}
						}
					}
				}
			}
			foreach my $term (keys %{ $self->terms->{any_field_terms}->{$boolean} }){ 
				if ($self->is_stopword($term)){
					my $err = 'Removed term ' . $term . ' which is too common';
					if ($boolean eq 'or'){
						$self->add_warning(400, $err, { term => $term });
						$self->log->warn($err);
					}
					else {
						$self->log->trace($err);
					}
					$num_removed_terms++;
					
					# Drop the term
					my $sphinx_term = $term;
					delete $self->terms->{any_field_terms}->{$boolean}->{$term};
					# Make sphinx term SQL term
#					if ($sphinx_term =~ /^\(\@(class|host|program) (\d+)\)$/){
#						$self->terms->{attr_terms}->{$boolean}->{'='}->{0}->{ $Fields::Field_order_to_meta_attr->{ $Fields::Field_to_order->{$1} } } = $2;
#					}
#					else {
						$self->terms->{any_field_terms_sql}->{$boolean}->{$term} = $sphinx_term;
#					}
				}
			}
		}
	}
	
#	foreach my $boolean (qw(and or not)){
#		foreach my $class_id (keys %{ $self->terms->{field_terms}->{$boolean} }){
#			foreach my $raw_field (keys %{ $self->terms->{field_terms}->{$boolean}->{$class_id} }){
#				next unless $self->terms->{field_terms}->{$boolean}->{$class_id}->{$raw_field};
#				for (my $i = 0; $i < (scalar @{ $self->terms->{field_terms}->{$boolean}->{$class_id}->{$raw_field} }); $i++){
#					my $term = $self->terms->{field_terms}->{$boolean}->{$class_id}->{$raw_field}->[$i];
#					my $resolved_term = $self->resolve_value($class_id, $term, $raw_field);
#					if ($term ne $resolved_term){
#						$term = '(' . $term . '|' . $resolved_term . ')';
#					}
#					$self->terms->{any_field_terms}->{$boolean}->{$term} = 1;
#				}
#			}
#		}
#	}
			
	# Determine if there are any other search fields.  If there are, then use host as a filter.
	$self->log->debug('attr_terms: ' . Dumper($self->terms->{attr_terms}));
	$self->log->debug('field_terms: ' . Dumper($self->terms->{field_terms}));
	$self->log->debug('any_field_terms: ' . Dumper($self->terms->{any_field_terms}));
	my $host_is_filter = 0;
	foreach my $boolean (qw(and or)){
		foreach my $class_id (keys %{ $self->terms->{field_terms}->{$boolean} }){
			next unless $class_id;
			$host_is_filter++;
		}
		foreach my $term (sort keys %{ $self->terms->{any_field_terms}->{$boolean} }){
			next if $term =~ /^\(\@host \d+\)$/; # Don't count host here
			$host_is_filter++;
		}
	}
	if ($host_is_filter){
		$self->log->trace('Using host as a filter because there were ' . $host_is_filter . ' query terms.');
		foreach my $boolean (qw(or and not)){
			foreach my $term (sort keys %{ $self->terms->{any_field_terms}->{$boolean} }){
				if ($term =~ /^\(\@host \d+\)$/){
					$self->log->trace('Deleted term ' . $term);
					delete $self->terms->{any_field_terms}->{$boolean}->{$term};
				}
			}
		}
	}
#	elsif (not keys %{ $self->terms->{field_terms} } and not keys %{ $self->terms->{attr_terms} }){
#		foreach my $boolean qw(or and not){
#			foreach	my $candidate_term (keys %{ $self->terms->{any_field_terms}->{$boolean} }){
#				if ($candidate_term =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/){
#					my $host_int = unpack('N*', inet_aton($candidate_term));
#					if ($self->user->is_permitted('host_id', $host_int)){
#						if ($self->archive){
#							# No good way of handling the and/or booleans for this in archive mode
#							$self->add_warning('Search will not include ' . $candidate_term . ' as a host, use host= for that if desired.');							
#						}
#						else {
#							$self->log->trace('adding host_int ' . $host_int);
#							delete $self->terms->{any_field_terms}->{$boolean}->{$candidate_term};
#							$self->terms->{any_field_terms}->{$boolean}->{'(@host ' . $host_int . '|' . $candidate_term . ')'} = 1; 
#							$self->highlights->{ _term_to_regex($candidate_term) } = 1;
#						}
#					}
#					else {
#						$self->log->warn("Insufficient permissions to query host_int $host_int");
#					}
#				}
#			}
#		}
#	}

	# Include all OR ints as any terms
	if (my $terms = $self->terms->{attr_terms}->{or}->{'='}){
		$self->log->debug('$terms: ' . Dumper($terms));
		foreach my $field_name (keys %$terms){
			next if $field_name eq 'host' or $field_name eq 'program' or $field_name eq 'class'; 
			foreach my $class_id (keys %{ $terms->{$field_name} }){
				foreach my $attr (keys %{ $terms->{$field_name}->{$class_id} }){
					foreach my $raw_value (@{ $terms->{$field_name}->{$class_id}->{$attr} }){
						$self->log->debug('considering term: ' . $raw_value);
						$attr =~ s/^attr\_//;
						my $resolved_value = $self->resolve_value($class_id, $raw_value, $attr);
						my $term = $self->_term_to_sphinx_term($class_id, $attr, $resolved_value);
						$self->terms->{any_field_terms}->{or}->{$term} = 1;
					}
				}
			}
		}
	}
	
	$self->log->trace("terms: " . Dumper($self->terms));
	$self->log->trace("classes: " . Dumper($self->classes));
	
	$self->log->debug('count_terms: ' . $self->index_term_count());
	# Decide if any attrs need to be search terms
	if (not $self->index_term_count()){
		# Favor non-meta attrs as keywords, choose the longest term
		my %candidates;
		foreach my $boolean (qw(and or)){
			if ($self->_has_positive_attrs($boolean)){
				my $terms = $self->terms->{attr_terms}->{$boolean}->{'='};
				$self->log->debug('$terms: ' . Dumper($terms));
				foreach my $field_name (keys %$terms){
					next if $field_name eq 'host' or $field_name eq 'program' or $field_name eq 'class'; 
					foreach my $class_id (keys %{ $terms->{$field_name} }){
						foreach my $attr (keys %{ $terms->{$field_name}->{$class_id} }){
							foreach my $raw_value (@{ $terms->{$field_name}->{$class_id}->{$attr} }){
								$self->log->debug('considering term: ' . $raw_value);
								next if $self->is_stopword($raw_value);
								my $col = $attr;
								$col =~ s/^attr\_//;
								my $resolved_value = $self->resolve_value($class_id, $raw_value, $col);
								$candidates{$resolved_value} = { boolean => $boolean, class_id => $class_id, real_field => $attr };
							}
						}
					}
				}
			}
			last if scalar keys %candidates; # If we have AND terms, just use those
		}
#		elsif ($self->terms->{attr_terms}->{or} and $self->terms->{attr_terms}->{or}->{'='} and scalar keys %{ $self->terms->{attr_terms}->{or}->{'='} }){
#			my $terms = $self->terms->{attr_terms}->{or}->{'='};
#			foreach my $field_name (keys %$terms){
#				next if $field_name eq 'host' or $field_name eq 'program' or $field_name eq 'class'; 
#				foreach my $class_id (keys %{ $terms->{$field_name} }){
#					foreach my $attr (keys %{ $terms->{$field_name}->{$class_id} }){
#						foreach my $raw_value (@{ $terms->{$field_name}->{$class_id}->{$attr} }){
#							$self->log->debug('considering term: ' . $raw_value);
#							if ($self->is_stopword($raw_value)){
#								$self->add_warning(200, $raw_value . ' is too common, not included in search', { term => $raw_value });
#								next;
#							}
#							my $col = $attr;
#							$col =~ s/^attr\_//;
#							my $resolved_value = $self->resolve_value($class_id, $raw_value, $col);
#							$candidates{$resolved_value} = { boolean => 'or', class_id => $class_id, real_field => $col };
#						}
#					}
#				}
#			}
#		}
		if (scalar keys %candidates or $self->_has_positive_attrs or not exists $self->datasources->{sphinx} or $self->has_import_search_terms or $self->_count_terms){
			# ok
		}
		else {
			$self->log->debug('terms: ' . Dumper($self->terms));
			throw(400, 'No positive value in query.', { query_string => $self->terms });
		}
		$self->log->debug('candidates: ' . Dumper(\%candidates));
		
		if (scalar keys %candidates){
			if ($self->_has_positive_attrs('and')){
				# Determine longest
				my $longest = (sort { length($b) <=> length($a) } keys %candidates)[0];
				my $info = $candidates{$longest};
				my $field = $info->{real_field};
				$field =~ s/^attr\_//;
				$longest = $self->_term_to_sphinx_term($info->{class_id}, $field, $longest);
				# Add as term
				if ($field !~ /^i/){
					push @{ $self->terms->{field_terms}->{and}->{ $info->{class_id} }->{$field} }, $longest;
				}
				else {
					$self->terms->{any_field_terms}->{and}->{$longest} = 1;
				}
			}
			else {
				# Include all OR's
				foreach my $term (keys %candidates){
					my $info = $candidates{$term};
					my $field = $info->{real_field};
					$field =~ s/^attr\_//;
					$term = $self->_term_to_sphinx_term($info->{class_id}, $field, $term);
					if ($field !~ /^i/){
						push @{ $self->terms->{field_terms}->{or}->{ $info->{class_id} }->{$field} }, $term;
					}
					else {
						$self->terms->{any_field_terms}->{or}->{$term} = 1;
					}
				}
			}
		}
		else {
			foreach my $boolean (qw(and or not)){
				foreach my $op (keys %{ $self->terms->{attr_terms}->{$boolean} }){
					next if $op =~ /[\<\>]/;
					if ($self->terms->{attr_terms}->{$boolean}->{$op}->{host} 
						and $self->terms->{attr_terms}->{$boolean}->{$op}->{host}->{0}
						and $self->terms->{attr_terms}->{$boolean}->{$op}->{host}->{0}->{host_id}){
						foreach my $host_int (@{ $self->terms->{attr_terms}->{$boolean}->{$op}->{host}->{0}->{host_id} }){
							if ($self->user->is_permitted('host_id', $host_int)){
								next if $self->archive; # archive queries don't need this
								next if $self->is_stopword($host_int);
								$self->log->trace('adding host_int ' . $host_int);
								#$self->terms->{any_field_terms}->{$boolean}->{'(@host ' . $host_int . ')'} = 1;
								push @{ $self->terms->{field_terms}->{$boolean}->{0}->{host} }, $host_int; # just for checking available fields later
								$self->highlights->{ _term_to_regex( inet_ntoa(pack('N*', $host_int)) ) } = 1;
							}
							else {
								my $host = inet_ntoa(pack('N*', $host_int));
								throw(403, "Insufficient permissions to query host $host", { host => $host });
							}
						}
					}
					elsif ($self->terms->{attr_terms}->{$boolean}->{$op}->{class} 
						and $self->terms->{attr_terms}->{$boolean}->{$op}->{class}->{0}
						and $self->terms->{attr_terms}->{$boolean}->{$op}->{class}->{0}->{class_id}
						and $Fields::Field_order_to_field->{ $Fields::Field_to_order->{class} }){
						foreach my $class_id (@{ $self->terms->{attr_terms}->{$boolean}->{$op}->{class}->{0}->{class_id} }){
							if ($self->user->is_permitted('class_id', $class_id)){
								next if $self->archive; # archive queries don't need this
								next if $self->is_stopword($class_id);
								$self->log->trace('adding class_id ' . $class_id);
								#$self->terms->{any_field_terms}->{$boolean}->{'(@class ' . $class_id . ')'} =1;
								push @{ $self->terms->{field_terms}->{$boolean}->{0}->{class} }, $class_id; # just for checking available fields later
								$self->highlights->{ _term_to_regex( $self->node_info->{classes_by_id}->{$class_id} ) } = 1;
							}
							else {
								throw(403, "Insufficient permissions to query class_id $class_id", { class => $self->node_info->{classes_by_id}->{$class_id} });
							}
						}
					}
					elsif ($self->terms->{attr_terms}->{$boolean}->{$op}->{program} 
						and $self->terms->{attr_terms}->{$boolean}->{$op}->{program}->{0}
						and $self->terms->{attr_terms}->{$boolean}->{$op}->{program}->{0}->{program_id}
						and $Fields::Field_order_to_field->{ $Fields::Field_to_order->{program} }){
						foreach my $program_id (@{ $self->terms->{attr_terms}->{$boolean}->{$op}->{program}->{0}->{program_id} }){
							if ($self->user->is_permitted('program_id', $program_id)){
								next if $self->archive; # archive queries don't need this
								next if $self->is_stopword($program_id);
								$self->log->trace('adding program_id ' . $program_id);
								#$self->terms->{any_field_terms}->{$boolean}->{'(@program ' . $program_id . ')'} = 1;
								push @{ $self->terms->{field_terms}->{$boolean}->{0}->{program} }, $program_id; # just for checking available fields later
								$self->highlights->{ _term_to_regex( $self->program_translations->{$program_id} ) } = 1;
							}
							else {
								throw(403, "Insufficient permissions to query program_id $program_id", { program => $self->program_translations->{$program_id} });
							}
						}
					}
				}
			}
		}
	}
	
	# Verify that we're still going to actually have query terms after the filtering has taken place	
	my $query_term_count = $self->index_term_count();
	
	# Save this query_term_count for later use
	$self->query_term_count($query_term_count);
	
#	# we might have a class-only query
#	foreach my $class (keys %{ $self->classes->{distinct} }){
#		unless ($num_removed_terms){ # this query used to have terms, so it wasn't really class-only
#			$query_term_count++;
#		}
#	}

	# we might have a class-only query
	foreach my $class (keys %{ $self->classes->{given} }){
		unless ($num_removed_terms){ # this query used to have terms, so it wasn't really class-only
			$query_term_count++;
		}
	}
	
	$self->log->debug('query_term_count: ' . $query_term_count . ', num_added_terms: ' . $num_added_terms);
	
	unless (not exists $self->datasources->{sphinx} or $query_term_count or $self->has_import_search_terms or $num_removed_terms){
		# See if we're doing an attr-only search here
		my $attrs = 0;
		foreach my $boolean (qw(and or not)){
			foreach my $op (keys %{ $self->terms->{attr_terms}->{$boolean} }){
				$attrs += scalar keys %{ $self->terms->{attr_terms}->{$boolean}->{$op} };
			}
		}
		if ($attrs){
			$self->log->debug('attrs only');
		}
		else {
			throw(403, 'All query terms were stripped based on permissions', { permissions => 1 });
		}
	}
	
	$self->log->debug('META_PARAMS: ' . Dumper($self->meta_params));
	
#	# Adjust query time params as necessary
#	if ($self->meta_params->{adjust_query_times}){
#		if ($self->start < $self->node_info->{indexes_min}){
#			$self->start = $self->node_info->{indexes_min};
#			$self->log->warn("Given start time too early, adjusting to " 
#				. epoch2iso($self->start));
#		}
#		elsif ($self->start > $self->node_info->{indexes_max}){
#			$self->start = $self->node_info->{indexes_max} - $self->conf->get('sphinx/index_interval');
#			$self->log->warn("Given start time too late, adjusting to " 
#				. epoch2iso($self->start));
#		}
#	}
	
	# Failsafe for times
	if ($self->meta_params->{start} or $self->meta_params->{end}){
		unless ($self->start){
			$self->start(0);
			$self->log->trace('set start to 0');
		}
		unless ($self->end){
			$self->end(time());
			$self->log->trace('set end to ' . time());
		}
	}
	
#	# Check to see if the query is after the latest end, but not in the future (this happens if the indexing process is backed up)
#	if ((exists $self->datasources->{sphinx} or exists $self->datasources->{archive}) and 
#		$self->start and $self->start <= time() and $self->start > $self->node_info->{indexes_max} and $self->start > $self->node_info->{archive_max}){
#		my $type = 'indexes';
#		if ($self->node_info->{archive_max} > $self->node_info->{indexes_max}){
#			$type = 'archive';
#		}
#		$self->log->debug('indexes_start_max: ' . $self->node_info->{'indexes_start_max'});
#		$self->log->debug('archive_start_max: ' . $self->node_info->{'archive_start_max'});
#		my $new_start_max = $self->node_info->{$type . '_start_max'};
#		$self->log->warn('Adjusted start_int ' . $self->start . ' to ' . $new_start_max . ' because it was after ' . $self->node_info->{$type . '_max'});
#		$self->start($new_start_max);
#	}
#	if ((exists $self->datasources->{sphinx} or exists $self->datasources->{archive}) and 
#		$self->end and $self->end < time() and $self->end > $self->node_info->{indexes_max} and $self->end > $self->node_info->{archive_max}){
#		my $type = 'indexes';
#		if ($self->node_info->{archive_max} > $self->node_info->{indexes_max}){
#			$type = 'archive';
#		}
#		my $new_max = $self->node_info->{$type . '_max'};
#		if ($new_max){
#			$self->log->warn('Adjusted end_int ' . $self->end . ' to ' . $new_max);
#			$self->end($new_max);
#		}
#	}
	
	# Final sanity check
	unless (defined $self->start and $self->end and $self->start <= $self->end){
		throw(416, 'Invalid start or end: ' . (scalar localtime($self->start)) . ' ' . (scalar localtime($self->end)), { start => $self->start, end => $self-> end });
	}
	
	$self->log->debug('going with times start: ' . (scalar localtime($self->start)) .  ' (' . $self->start . ') and end: ' .
		(scalar localtime($self->end)) . ' (' . $self->end . ')');
	
	# Exclude our from_peer
	if ($self->from_peer and $self->from_peer ne '_external'){
		$self->log->debug('Not executing query on ' . $self->from_peer . ' which is my from_peer to avoid a loop.');
		$self->nodes->{excluded}->{ $self->from_peer } = 1;
	}
	
	return 1;
}

sub _has_positive_attrs {
	my $self = shift;
	my $given_boolean = shift;
	
	my @booleans;
	if ($given_boolean){
		@booleans = ($given_boolean);
	}
	else {
		@booleans = qw(and or);
	}
	
	my $count = 0;
	foreach my $boolean (@booleans){
		$count += ($self->terms->{attr_terms}->{$boolean} 
			and $self->terms->{attr_terms}->{$boolean}->{'='} 
			and scalar keys %{ $self->terms->{attr_terms}->{$boolean}->{'='} }) ? 1 : 0;
	}
	
	return $count;
}

sub _count_terms {
	my $self = shift;
	my $query_term_count = 0;
		
	foreach my $boolean (qw(or and)){
		$query_term_count += scalar keys %{ $self->terms->{any_field_terms}->{$boolean} };
		$query_term_count += scalar keys %{ $self->terms->{any_field_terms_sql}->{$boolean} };
	}
	foreach my $boolean (qw(or and)){
		foreach my $class_id (keys %{ $self->terms->{field_terms}->{$boolean} }){
			foreach my $field (keys %{ $self->terms->{field_terms}->{$boolean}->{$class_id} }){
				$query_term_count += scalar @{ $self->terms->{field_terms}->{$boolean}->{$class_id}->{$field} };
			}
		}
	}
	
	if ($self->terms->{field_terms_sql}){
		foreach my $boolean (qw(or and)){
			next unless $self->terms->{field_terms_sql}->{$boolean};
			foreach my $class_id (keys %{ $self->terms->{field_terms_sql}->{$boolean} }){
				foreach my $field (keys %{ $self->terms->{field_terms_sql}->{$boolean}->{$class_id} }){
					$query_term_count += scalar @{ $self->terms->{field_terms_sql}->{$boolean}->{$class_id}->{$field} };
				}
			}
		}
	}
	return $query_term_count;
}

sub index_term_count {
	my $self = shift;
	my $query_term_count = 0;
		
	foreach my $boolean (qw(or and)){
		$query_term_count += scalar keys %{ $self->terms->{any_field_terms}->{$boolean} };
	}
	foreach my $boolean (qw(or and)){
		foreach my $class_id (keys %{ $self->terms->{field_terms}->{$boolean} }){
			foreach my $field (keys %{ $self->terms->{field_terms}->{$boolean}->{$class_id} }){
				$query_term_count += scalar @{ $self->terms->{field_terms}->{$boolean}->{$class_id}->{$field} };
			}
		}
	}
	return $query_term_count;
}

sub is_stopword {
	my $self = shift;
	my $keyword = shift;
	
	my $stopwords = $self->conf->get('stopwords');
	
	# Check all field terms to see if they are a stopword and warn if necessary
	if ($stopwords and ref($stopwords) and ref($stopwords) eq 'HASH'){
		if (exists $stopwords->{ lc($keyword) }){
			return 1;
		}
		elsif ($keyword =~ /^"([^"]+)"$/){
			my @possible_terms = split(/\s+/, $1);
			foreach my $term (@possible_terms){
				if (exists $stopwords->{ lc($term) }){
					$self->log->trace('Found stopword ' . $term . ' embedded in quoted term ' . $keyword);
					return 1;
				}
			}
		}
	}
	return 0;
}

sub filter_stopwords {
	my $self = shift;
	my $record = shift;
	
	# Filter any records which have stopwords
	if (scalar keys %{ $self->terms->{any_field_terms_sql}->{and} }){
		my $to_find = scalar keys %{ $self->terms->{any_field_terms_sql}->{and} };
		STOPWORD_LOOP: foreach my $stopword (keys %{ $self->terms->{any_field_terms_sql}->{and} }){
			my $regex = _term_to_regex($stopword);
			foreach my $field (qw(msg program node host class)){
				if ($record->{$field} =~ qr/$regex/i){
					$self->log->debug('Found stopword: ' . $stopword . ' for term ' . $record->{$field} . ' and field ' . $field);
					$to_find--;
					last STOPWORD_LOOP;
				}
			}
			foreach my $field_hash (@{ $record->{_fields} }){
				if ($field_hash->{value} =~ qr/$regex/i){
					$self->log->debug('Found stopword: ' . $stopword . ' for term ' . $field_hash->{value});
					$to_find--;
					last STOPWORD_LOOP;
				}
			}
		}
		return 0 if $to_find;
	}
	
	if (scalar keys %{ $self->terms->{any_field_terms_sql}->{not} }){
		foreach my $stopword (keys %{ $self->terms->{any_field_terms_sql}->{not} }){
			my $regex = _term_to_regex($stopword);
			foreach my $field (qw(msg program node host class)){
				if ($record->{$field} =~ qr/$regex/i){
					$self->log->debug('Found not stopword: ' . $stopword . ' for term ' . $record->{$field} . ' and field ' . $field);
					return 0;
				}
			}
			foreach my $field_hash (@{ $record->{_fields} }){
				if ($field_hash->{value} =~ qr/$regex/i){
					$self->log->debug('Found not stopword: ' . $stopword . ' for term ' . $field_hash->{value});
					return 0;
				}
			}
		}
	}
	return 1;
}

sub has_stopword_terms {
	my $self = shift;
	my $terms_count = (scalar keys %{ $self->terms->{any_field_terms_sql}->{and} }) + (scalar keys %{ $self->terms->{any_field_terms_sql}->{not} });
	if ($self->terms->{field_terms_sql}){
		foreach my $boolean (keys %{ $self->terms->{field_terms_sql} }){
			foreach my $class_id (keys %{ $self->terms->{field_terms_sql}->{$boolean} }){
				foreach my $raw_field (keys %{ $self->terms->{field_terms_sql}->{$boolean}->{$class_id} }){
					foreach my $term (@{ $self->terms->{field_terms_sql}->{$boolean}->{$class_id}->{$raw_field} }){
						$terms_count++;
					}
				}
			}
		}
	}
	return $terms_count;
}

sub _parse_query_term {
	my $self = shift;
	return 1 unless $self->datasources->{sphinx}; # short-circuit here to prevent parsing logic extending into external datasources
	my $terms = shift;
	my $given_operator = shift;
	
	$self->log->debug('terms: ' . Dumper($terms));
	
	foreach my $operator (keys %{$terms}){
		my $effective_operator = $operator;
		if ($given_operator){
			if ($given_operator eq '-' and ($effective_operator eq '' or $effective_operator eq '+')){
				$effective_operator = '-'; # invert the AND or OR
			}
			elsif ($given_operator eq '+' and $effective_operator eq '-'){
				$effective_operator = '-';
			}
		}
		
		my $arr = $terms->{$operator};
		foreach my $term_hash (@{$arr}){
			next unless defined $term_hash->{value};
			
			# Recursively handle parenthetical directives
			if (ref($term_hash->{value}) eq 'HASH'){
				$self->_parse_query_term($term_hash->{value}, $effective_operator);
				next;
			}
			
			if ($term_hash->{value} =~ /^\$(\w+)/){
				$self->log->debug('got macro ' . $1);
				$self->_parse_query_string($self->_resolve_macro($1), $effective_operator);
				next;
			}
			
			# Make field lowercase
			$term_hash->{field} = lc($term_hash->{field});
			
			# Escape any digit-dash-word combos (except for host or program)
			#$term_hash->{value} =~ s/(\d+)\-/$1\\\\\-/g unless ($self->archive or $term_hash->{field} eq 'program' or $term_hash->{field} eq 'host');
						
			if ($term_hash->{field} eq 'start'){
				# special case for start/end
				if ($term_hash->{value} =~ /^\d+$/){
					$self->start(int($term_hash->{value}));
				}
				else {
					#$self->start(UnixDate(ParseDate($term_hash->{value}), "%s"));
					my $tz_diff = $self->timezone_diff($term_hash->{value});
					$self->start(UnixDate(ParseDate($term_hash->{value}), "%s") + $tz_diff);
				}
				$self->log->debug('start is now: ' . $self->start .', ' . (scalar localtime($self->start)));
				next;
			}
			elsif ($term_hash->{field} eq 'end'){
				# special case for start/end
				if ($term_hash->{value} =~ /^\d+$/){
					$self->end(int($term_hash->{value}));
				}
				else {
					#$self->end(UnixDate(ParseDate($term_hash->{value}), "%s"));
					my $tz_diff = $self->timezone_diff($term_hash->{value});
					$self->end(UnixDate(ParseDate($term_hash->{value}), "%s") + $tz_diff);
				}
				next;
			}
			elsif ($term_hash->{field} eq 'limit'){
				# special case for limit
				$self->limit(sprintf("%d", $term_hash->{value}));
				throw(400, 'Invalid limit', { term => 'limit' }) unless $self->limit > -1;
				next;
			}
			elsif ($term_hash->{field} eq 'offset'){
				# special case for offset
				$self->offset(sprintf("%d", $term_hash->{value}));
				throw(400, 'Invalid offset', { term => 'offset' }) unless $self->offset > -1;
				next;
			}
			elsif ($term_hash->{field} eq 'class'){
				# special case for class
				my $class;
				$self->log->trace('classes: ' . Dumper($self->node_info->{classes}));
				if ($self->node_info->{classes}->{ uc($term_hash->{value}) }){
					$class = lc($self->node_info->{classes}->{ uc($term_hash->{value}) });
				}
				elsif (uc($term_hash->{value}) eq 'ANY'){
					my @classes;
					foreach my $class_name (keys %{ $self->node_info->{classes} }){
						next if $class_name eq 'ANY';
						push @classes, { field => 'class', value => $class_name, op => $term_hash->{op} };
					}
					$self->_parse_query_term({ '' => \@classes }, $effective_operator);
					next;
				}
				else {
					throw(400, "Unknown class $term_hash->{value}", { term => $term_hash->{value} });
				}
				
				if ($effective_operator eq '-'){
					# We're explicitly removing this class
					$self->classes->{excluded}->{ $class } = 1;
				}
				else {
					$self->classes->{given}->{ $class } = 1;
				}
				$self->log->debug("Set operator $effective_operator for given class " . $term_hash->{value});		
				#next;
			}
			elsif ($term_hash->{field} eq 'groupby'){
				my $value = lc($term_hash->{value});
				#TODO implement groupby import with new import system
#				if ($value =~ /^import\_/){
#					die('Invalid groupby ' . $value) unless grep { $_ eq $value } @$Fields::Import_fields;
#					$self->import_groupby($value);
#					$self->log->trace('Setting groupby to host on behalf of an import groupby ' . $self->import_groupby);
#					$value = 'host';
#				}
				my $field_infos = $self->get_field($value);
				$self->log->trace('$field_infos ' . Dumper($field_infos));
				
				if (grep { $_ eq $value } @$Fields::Import_fields){
					throw(400, 'Cannot group by an import meta tag', { term => $value });
				}
				elsif (not scalar keys %$field_infos and $value ne 'node'){
					throw(404, 'Field ' . $value . ' not a valid groupby value', { term => $value });
				}
				else {
					$self->add_groupby(lc($value));
					foreach my $class_id (keys %$field_infos){
						$self->classes->{groupby}->{$class_id} = 1;
					}
					$self->log->trace("Set groupby " . Dumper($self->groupby));
				}
				next;
			}
			elsif ($term_hash->{field} eq 'orderby'){
				my $value = lc($term_hash->{value});
				my $field_infos = $self->get_field($value);
				$self->log->trace('$field_infos ' . Dumper($field_infos));
				if ($field_infos or $value eq 'node'){
					$self->orderby($value);
					foreach my $class_id (keys %$field_infos){
						$self->classes->{groupby}->{$class_id} = 1;
					}
					$self->log->trace("Set orderby " . Dumper($self->orderby));
				}
				next;
			}
			elsif ($term_hash->{field} eq 'orderby_dir'){
				if (uc($term_hash->{value}) eq 'DESC'){
					$self->orderby_dir('DESC');
				}
				next;
			}
			elsif ($term_hash->{field} eq 'node'){
				if ($term_hash->{value} =~ /^[\w\.\:]+$/){
					if ($effective_operator eq '-'){
						$self->nodes->{excluded}->{ $term_hash->{value} } = 1;
					}
					else {
						$self->nodes->{given}->{ $term_hash->{value} } = 1;
					}
				}
				next;
			}
			elsif ($term_hash->{field} eq 'cutoff'){
				$self->limit($self->cutoff(sprintf("%d", $term_hash->{value})));
				throw(400, 'Invalid cutoff', { term => 'cutoff' }) unless $self->cutoff > -1;
				$self->log->trace("Set cutoff " . $self->cutoff);
				next;
			}
			elsif ($term_hash->{field} eq 'datasource'){
				delete $self->datasources->{sphinx}; # no longer using our normal datasource
				$self->datasources->{ $term_hash->{value} } = 1;
				$self->log->trace("Set datasources " . Dumper($self->datasources));
				# Stop parsing immediately as the rest will be done by the datasource itself
				return 1;
			}
			elsif ($term_hash->{field} eq 'nobatch'){
				$self->meta_params->{nobatch} = 1;
				$self->log->trace("Set batch override.");
				next;
			}
			elsif ($term_hash->{field} eq 'livetail'){
				$self->meta_params->{livetail} = 1;
				$self->livetail(1);
				$self->archive(1);
				$self->log->trace("Set livetail.");
				next;
			}
			elsif ($term_hash->{field} eq 'archive'){
				$self->meta_params->{archive} = 1;
				$self->archive(1);
				$self->log->trace("Set archive.");
				next;
			}
			elsif ($term_hash->{field} eq 'analytics'){
				$self->meta_params->{analytics} = 1;
				$self->analytics(1);
				$self->log->trace("Set analytics.");
				next;
			}
			
			my $orig_value = $term_hash->{value};
			if ($term_hash->{field} eq 'program' or $term_hash->{field} eq 'host' or $term_hash->{field} =~ /proto/){
				# Fine as is
			}
			elsif ($self->archive){
				# Escape any special chars
				$term_hash->{value} =~ s/([^a-zA-Z0-9\.\_\-\@])/\\$1/g;
			}
			elsif ($self->livetail){
				# Escape any slashes since this will become a regex
				$term_hash->{value} =~ s/\//\\\//g;
			}
			elsif ($term_hash->{field} eq 'timeout'){
				# special case for timeout
				$self->timeout(int($term_hash->{value}) * 1000);
				throw(400, 'Invalid timeout', { term => 'timeout' }) unless $self->timeout > -1;
				$self->max_query_time($self->timeout * .9);
				next;
			}
			else {
				# Get rid of any non-indexed chars
				$term_hash->{value} =~ s/[^a-zA-Z0-9\.\@\-\_\\]/\ /g;
				# Escape backslashes followed by a letter
				$term_hash->{value} =~ s/\\([a-zA-Z])/\ $1/g;
				#$term_hash->{value} =~ s/\\\\/\ /g; # sphinx doesn't do this for some reason
				# Escape any '@' or sphinx will error out thinking it's a field prefix
				if ($term_hash->{value} =~ /\@/ and not $term_hash->{quote}){
					# need to quote
					$term_hash->{value} = '"' . $term_hash->{value} . '"';
				}
				# Escape any hyphens
				$term_hash->{value} =~ s/\-/\\\\\-/g;
				# Escape any free-standing hypens
				#$term_hash->{value} =~ s/^\-$/\\\-/g;
				#$term_hash->{value} =~ s/([^a-zA-Z0-9\.\_\-\@])\-([^a-zA-Z0-9\.\_\-\@]*)/$1\\\\\-$2/g;
				# Sphinx can only handle numbers up to 15 places (though this is fixed in very recent versions)
#				if ($term_hash->{value} =~ /^[0-9]{15,}$/){
#					throw(400, 'Integer search terms must be 15 or fewer digits, received ' 
#						. $term_hash->{value} . ' which is ' .  length($term_hash->{value}) . ' digits.', { term => $term_hash->{value} });
#				}
				if($term_hash->{quote}){
					$term_hash->{value} = $self->normalize_quoted_value($term_hash->{value});
				}
				
				if ($term_hash->{value} =~ /^"?\s+"?$/){
					my $err = 'Term ' . $orig_value . ' was comprised of only non-indexed chars and removed';
					$self->add_warning(400, $err, { term => $term_hash->{value} });
					$self->log->warn($err);
					next;
				}
			}
			
			$self->log->debug('term_hash value now: ' . $term_hash->{value});
			
			my $boolean = 'or';
				
			# Reverse if necessary
			if ($effective_operator eq '-' and $term_hash->{op} eq '!='){
				$boolean = 'and';
			}
			elsif ($effective_operator eq '-' and $term_hash->{op} eq '='){
				$boolean = 'not';
			}
			elsif ($effective_operator eq '+'){
				$boolean = 'and';
			}
			elsif ($effective_operator eq '-'){
				$boolean = 'not';
			}
									
			# Process a field/value or attr/value
			if ($term_hash->{field} and defined $term_hash->{value}){
				
				my $operators = {
					'>' => 1,
					'>=' => 1,
					'<' => 1,
					'<=' => 1,
					'!=' => 1, 
				};
				# Default unknown operators to AND
				unless ($operators->{ $term_hash->{op} }){
					$term_hash->{op} = '=';
				}
				
				if ($term_hash->{field} =~ /^import\_(\w+)/){
					throw(400, 'Invalid import field ' . $term_hash->{field}, { term => $term_hash->{field} }) unless grep { $_ eq $term_hash->{field} } @$Fields::Import_fields;
					push @{ $self->import_search_terms }, { field => $1, value => $term_hash->{value}, 
						op => $term_hash->{op}, boolean => $effective_operator };
					next;
				}
				
				my $values = $self->resolve(
					$term_hash->{field}, 
					$term_hash->{value}, 
					$term_hash->{op}
				);
				
				if (not scalar keys %{ $values->{attrs} } and not scalar keys %{ $values->{fields} }){
					throw(400, 'Invalid field: ' . $term_hash->{field}, { term => $term_hash->{field} });
				}
				
				$self->terms->{distinct_fields}->{ $term_hash->{field} } = 1;
				
				# Mark down any program translations
				if (lc($term_hash->{field}) eq 'program'){
					$self->program_translations->{ crc32( lc($term_hash->{value}) ) } = lc($term_hash->{value});
				}
				
				# Set fields for searching
				if ($term_hash->{op} !~ /[\<\>]/){ # ignore ranges
					foreach my $class_id (keys %{ $values->{fields} }){
						foreach my $real_field (keys %{ $values->{fields}->{$class_id} }){
							$self->terms->{field_terms}->{$boolean}->{$class_id}->{$real_field} ||= [];
							push @{ $self->terms->{field_terms}->{$boolean}->{$class_id}->{$real_field} }, 
								$values->{fields}->{$class_id}->{$real_field};
						}	
					}
				}
				
				# Set attributes for searching
				foreach my $class_id (keys %{ $values->{attrs} }){
#					# If not a range search, not already a field term, and not a class 0 attr, add text to any field search
#					if ($term_hash->{op} !~ /[\<\>]/ and not exists $self->terms->{field_terms}->{$boolean}->{$class_id}
#						and $term_hash->{field} =~ /country_code/i){ # one-off for weird way country_code works
#						push @{ $self->terms->{any_field_terms}->{$boolean} },
#							join('', unpack('c*', pack('A*', uc($term_hash->{value}))));
#					}
#					elsif ($term_hash->{op} !~ /[\<\>]/ and not exists $self->terms->{field_terms}->{$boolean}->{$class_id}){
#						if ($class_id){ #skip class 0
#							if ($term_hash->{field} =~ /proto/){
#								# proto is special because it is represented as both an integer and string, so search for both
#								my @compound_terms = ($term_hash->{value}); # compound an OR for just these potential values
#								foreach my $real_field (keys %{ $values->{attrs}->{$class_id} }){
#									$self->log->trace('Adding on integer representation of protocol: ' . $values->{attrs}->{$class_id}->{$real_field});
#									push @compound_terms, $values->{attrs}->{$class_id}->{$real_field};
#								}
#								push @{ $self->terms->{any_field_terms}->{$boolean} }, '(' . join('|', @compound_terms) . ')';
#							}
#							elsif ($term_hash->{value} =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/){
#								# Handle an IPv4 value
#								push @{ $self->terms->{any_field_terms}->{$boolean} }, '(' . $term_hash->{value} . '|' . unpack('N*', inet_aton($term_hash->{value})) . ')';
#							}
#							else {	
#								push @{ $self->terms->{any_field_terms}->{$boolean} }, $term_hash->{value};
#							}
#						}
#					}
					my $field_info = $self->get_field($term_hash->{field})->{$class_id};
					unless ($field_info->{field_type}){
						$self->log->warn('No field_info for ' . $term_hash->{field} . ': ' . Dumper($field_info));
						next;
					}
					next if $field_info->{field_type} eq 'string'; # skip string attributes because our value may be only matching part of the field
					$self->terms->{attr_terms}->{$boolean}->{ $term_hash->{op} }->{ $term_hash->{field} } ||= {};
					foreach my $real_field (keys %{ $values->{attrs}->{$class_id} }){
						my $intvalue = $values->{attrs}->{$class_id}->{$real_field};
						unless ($intvalue =~ /^\d+$/){
							throw(400, 'Found a non-integer for an integer field', { term => $intvalue });
						}
						$self->terms->{attr_terms}->{$boolean}->{ $term_hash->{op} }->{ $term_hash->{field} }->{$class_id}->{$real_field} ||= [];
						push @{ $self->terms->{attr_terms}->{$boolean}->{ $term_hash->{op} }->{ $term_hash->{field} }->{$class_id}->{$real_field} }, $intvalue;
					}
				}
			}				
				
			# Otherwise there was no field given, search all fields
			elsif (defined $term_hash->{value}){
				# If the term is an IP, let's also search for its integer representation
				if ($term_hash->{value} =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/){
					$self->terms->{any_field_terms}->{$boolean}->{'(' . $term_hash->{value} . '|' . unpack('N*', inet_aton($term_hash->{value})) . ')'} = 1;
					if ($boolean ne 'not'){
						$self->terms->{any_field_terms}->{or}->{ $term_hash->{value} } = 1;
						$self->terms->{any_field_terms}->{or}->{ unpack('N*', inet_aton($term_hash->{value})) } = 1;
					}
				}
				else {
					$self->terms->{any_field_terms}->{$boolean}->{ $term_hash->{value} } = 1;
				}
			}
			else {
				throw(400, "no field or value given to match field $term_hash->{field}", { term => $term_hash->{field} });
			}
		}
	}
	
	return 1;
}

sub set_directive {
	my $self = shift;
	my $directive = shift;
	my $value = shift;
	my $op = shift;
	$op ||= '=';
	
	if ($directive eq 'start'){
		# special case for start/end
		if ($value =~ /^\d+$/){
			$self->start(int($value));
		}
		else {
			#$self->start(UnixDate(ParseDate($value), "%s"));
			my $tz_diff = $self->timezone_diff($value);
			$self->start(UnixDate(ParseDate($value), "%s") + $tz_diff);
		}
		$self->log->debug('start is now: ' . $self->start .', ' . (scalar localtime($self->start)));
	}
	elsif ($directive eq 'end'){
		# special case for start/end
		if ($value =~ /^\d+$/){
			$self->end(int($value));
		}
		else {
			my $tz_diff = $self->timezone_diff($value);
			$self->end(UnixDate(ParseDate($value), "%s") + $tz_diff);
		}
	}
	elsif ($directive eq 'limit'){
		# special case for limit
		$self->limit(sprintf("%d", $value));
		throw(400, 'Invalid limit', { term => 'limit' }) unless $self->limit > -1;
	}
	elsif ($directive eq 'offset'){
		# special case for offset
		$self->offset(sprintf("%d", $value));
		throw(400, 'Invalid offset', { term => 'offset' }) unless $self->offset > -1;
	}
	elsif ($directive eq 'class'){
		# special case for class
		my $class;
		$self->log->trace('classes: ' . Dumper($self->node_info->{classes}));
		if ($self->node_info->{classes}->{ uc($value) }){
			$class = lc($self->node_info->{classes}->{ uc($value) });
		}
		elsif (uc($value) eq 'ANY'){
			my @classes;
			foreach my $class_name (keys %{ $self->node_info->{classes} }){
				next if $class_name eq 'ANY';
				push @classes, { field => 'class', value => $class_name, op => $op };
			}
			$self->_parse_query_term({ '' => \@classes }, $op);
		}
		else {
			throw(400, "Unknown class $value", { term => $value });
		}
		
		if ($op eq '-'){
			# We're explicitly removing this class
			$self->classes->{excluded}->{ $class } = 1;
		}
		else {
			$self->classes->{given}->{ $class } = 1;
		}
		$self->log->debug("Set operator $op for given class " . $value);		
	}
	elsif ($directive eq 'groupby'){
		my $value = lc($value);
		#TODO implement groupby import with new import system
		my $field_infos = $self->get_field($value);
		$self->log->trace('$field_infos ' . Dumper($field_infos));
		if ($field_infos or $value eq 'node'){
			$self->add_groupby(lc($value));
			foreach my $class_id (keys %$field_infos){
				$self->classes->{groupby}->{$class_id} = 1;
			}
			$self->log->trace("Set groupby " . Dumper($self->groupby));
		}
	}
	elsif ($directive eq 'orderby'){
		my $value = lc($value);
		my $field_infos = $self->get_field($value);
		$self->log->trace('$field_infos ' . Dumper($field_infos));
		if ($field_infos or $value eq 'node'){
			$self->orderby($value);
			foreach my $class_id (keys %$field_infos){
				$self->classes->{groupby}->{$class_id} = 1;
			}
			$self->log->trace("Set orderby " . Dumper($self->orderby));
		}
	}
	elsif ($directive eq 'orderby_dir'){
		if (uc($value) eq 'DESC'){
			$self->orderby_dir('DESC');
		}
	}
	elsif ($directive eq 'node'){
		if ($value =~ /^[\w\.\:]+$/){
			if ($op eq '-'){
				$self->nodes->{excluded}->{ $value } = 1;
			}
			else {
				$self->nodes->{given}->{ $value } = 1;
			}
		}
	}
	elsif ($directive eq 'cutoff'){
		$self->limit($self->cutoff(sprintf("%d", $value)));
		throw(400, 'Invalid cutoff', { term => 'cutoff' }) unless $self->cutoff > -1;
		$self->log->trace("Set cutoff " . $self->cutoff);
	}
	elsif ($directive eq 'datasource'){
		delete $self->datasources->{sphinx}; # no longer using our normal datasource
		$self->datasources->{ $value } = 1;
		$self->log->trace("Set datasources " . Dumper($self->datasources));
	}
	elsif ($directive eq 'nobatch'){
		$self->meta_params->{nobatch} = 1;
		$self->log->trace("Set batch override.");
	}
	elsif ($directive eq 'livetail'){
		$self->meta_params->{livetail} = 1;
		$self->livetail(1);
		$self->archive(1);
		$self->log->trace("Set livetail.");
	}
	elsif ($directive eq 'archive'){
		$self->meta_params->{archive} = 1;
		$self->archive(1);
		$self->log->trace("Set archive.");
		next;
	}
	elsif ($directive eq 'analytics'){
		$self->meta_params->{analytics} = 1;
		$self->analytics(1);
		$self->log->trace("Set analytics.");
	}
	else {
		throw(400, 'Invalid directive', { term => $directive });
	}
}

sub cancel {
	my $self = shift;
	
	my ($query, $sth);
	$query = 'UPDATE query_log SET num_results=-2 WHERE qid=?';
	$sth = $self->db->prepare($query);
	$sth->execute($self->qid);
	return 1;
}

sub check_cancelled {
	my $self = shift;
	my ($query, $sth);
	$query = 'SELECT num_results FROM query_log WHERE qid=?';
	$sth = $self->db->prepare($query);
	$sth->execute($self->qid);
	my $row = $sth->fetchrow_hashref;
	if (defined $row->{num_results} and $row->{num_results} eq -2){
		$self->log->info('Query ' . $self->qid . ' has been cancelled');
		$self->cancelled(1);
		return 1;
	}
	return 0;
}

sub mark_batch_start {
	my $self = shift;
	# Record that we're starting so no one else starts it
	my ($query, $sth);
	$sth = $self->db->prepare('UPDATE query_log SET num_results=-1 WHERE qid=?');
	$sth->execute($self->qid);
	return $sth->rows;
}

sub mark_livetail_start {
	my $self = shift;
	# Record that we're starting so no one else starts it
	$self->log->trace('marked livetail start');
	my ($query, $sth);
	$sth = $self->db->prepare('UPDATE query_log SET num_results=-3 WHERE qid=?');
	$sth->execute($self->qid);
	return $sth->rows;
}

sub _resolve_macro {
	my $self = shift;
	my $macro = shift;
	
	my ($query, $sth);
	
	$macro = lc($macro);
	
	# Create whois-based built-ins
	my %nets;
	my $subnets = $self->conf->get('transforms/whois/known_subnets');
	if ($subnets){
		foreach my $start (keys %$subnets){
			my $org = lc($subnets->{$start}->{org});
			$org =~ s/[^\w\_]//g;
			$nets{'src_' . $org } .= ' +srcip>=' . $start . ' +srcip<=' . $subnets->{$start}->{end};
			$nets{'dst_' . $org } .= ' +dstip>=' . $start . ' +dstip<=' . $subnets->{$start}->{end};
			$nets{$org} .= ' +srcip>=' . $start . ' +srcip<=' . $subnets->{$start}->{end} . ' +dstip>=' . $start . ' +dstip<=' . $subnets->{$start}->{end};
			$nets{src_local} .= ' +srcip>=' . $start . ' +srcip<=' . $subnets->{$start}->{end};
			$nets{dst_local} .= ' +dstip>=' . $start . ' +dstip<=' . $subnets->{$start}->{end};
		}
	}
		
	if ($self->user->username eq 'system'){
		# Try to find macro in available local prefs
		$query = 'SELECT * FROM preferences WHERE type=? AND name=? ORDER BY id DESC LIMIT 1';
		$sth = $self->db->prepare($query);
		$sth->execute('saved_query', $macro);
		my $row = $sth->fetchrow_hashref;
		return $row ? $row->{value} : '';
	}
	elsif ($self->user->preferences and $self->user->preferences->{tree}->{saved_query} and 
		$self->user->preferences->{tree}->{saved_query}->{$macro}){
		return $self->user->preferences->{tree}->{saved_query}->{$macro};
	}
	elsif (exists $nets{$macro}){
		return $nets{$macro};
	}
	else {
		$self->log->debug('macros available: ' . Dumper($self->user->preferences->{tree}));
		throw(400, 'Invalid macro (saved search): ' . $macro, { term => $macro });
	}
	
}

sub _term_to_sphinx_term {
	my $self = shift;
	my $class_id = shift;
	my $col = shift;
	my $value = shift;
	
	my $resolved_value = $self->normalize_value($class_id, $value, $Fields::Field_to_order->{$col});
	if ($value ne $resolved_value){
		return '(' . $value . '|' . $resolved_value . ')';
	}
	return $value;
}

sub convert_to_archive {
	my $self = shift;
	$self->query_term_count(0);
	foreach my $boolean (qw(and or not)){
		foreach my $term (keys %{ $self->terms->{any_field_terms}->{$boolean} }){ 
			# Drop the term
			delete $self->terms->{any_field_terms}->{$boolean}->{$term};
			my $sphinx_term = $term;
			# Make sphinx term SQL term
			if ($sphinx_term =~ /^\(\@(class|host|program) (\d+)\)$/){
				$self->terms->{attr_terms}->{$boolean}->{'='}->{0}->{ $Fields::Field_order_to_meta_attr->{ $Fields::Field_to_order->{$1} } } = $2;
			}
			else {
				$self->terms->{any_field_terms_sql}->{$boolean}->{$term} = $sphinx_term;
			}
		}
	}
	# Put the field_terms_sql back to field_terms now that we've done the count
	if ($self->terms->{field_terms_sql}){
		foreach my $boolean (keys %{ $self->terms->{field_terms_sql} }){
			foreach my $class_id (keys %{ $self->terms->{field_terms_sql}->{$boolean} }){
				foreach my $raw_field (keys %{ $self->terms->{field_terms_sql}->{$boolean}->{$class_id} }){
					foreach my $term (@{ $self->terms->{field_terms_sql}->{$boolean}->{$class_id}->{$raw_field} }){
						push @{ $self->terms->{field_terms}->{$boolean}->{$class_id}->{$raw_field} }, $term;
					}
				}
			}
		}
	}
	delete $self->terms->{field_terms_sql};
}

sub dedupe_warnings {
	my $self = shift;
	my %uniq;
	foreach my $warning ($self->all_warnings){
		my $key;
		if (blessed($warning)){
			$key = $warning->code . $warning->message . $self->json->encode($warning->data);
		}
		elsif (ref($warning)){
			$key = $warning->{code} . $warning->{message} . $self->json->encode($warning->{data});
		}
		else {
			$self->log->warn('Improperly formatted warning received: ' . $warning);
			$key = $warning;
			$warning = { code => 500, message => $warning, data => {} };
		}
		$uniq{$key} ||= [];
		push @{ $uniq{$key} }, $warning;
	}
	
	my @dedupe;
	foreach my $key (keys %uniq){
		push @dedupe, $uniq{$key}->[0];
	}
	$self->warnings([@dedupe]);
}

1;