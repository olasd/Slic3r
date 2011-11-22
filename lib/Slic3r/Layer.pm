package Slic3r::Layer;
use Moo;

use Math::Clipper ':all';
use Slic3r::Geometry qw(polygon_lines points_coincide angle3points polyline_lines nearest_point
    line_length collinear X Y A B PI);
use Slic3r::Geometry::Clipper qw(union_ex diff_ex intersection_ex PFT_EVENODD);
use XXX;

# a sequential number of layer, starting at 0
has 'id' => (
    is          => 'ro',
    #isa         => 'Int',
    required    => 1,
);

# collection of spare segments generated by slicing the original geometry;
# these need to be merged in continuos (closed) polylines
has 'lines' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::Line]',
    default => sub { [] },
);

# collection of surfaces generated by slicing the original geometry
has 'surfaces' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::Surface]',
    default => sub { [] },
);

# collection of surfaces representing bridges
has 'bridges' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::Surface::Bridge]',
    default => sub { [] },
);

# collection of surfaces to make perimeters for
has 'perimeter_surfaces' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::Surface]',
    default => sub { [] },
);

# ordered collection of extrusion paths to build all perimeters
has 'perimeters' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::ExtrusionLoop]',
    default => sub { [] },
);

# ordered collection of extrusion paths to build skirt loops
has 'skirts' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::ExtrusionLoop]',
    default => sub { [] },
);

# collection of surfaces generated by offsetting the innermost perimeter(s)
# they represent boundaries of areas to fill (grouped by original objects)
has 'fill_surfaces' => (
    is      => 'rw',
    #isa     => 'ArrayRef[ArrayRef[Slic3r::Surface]]',
    default => sub { [] },
);

# ordered collection of extrusion paths to fill surfaces
has 'fills' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::ExtrusionPath]',
    default => sub { [] },
);

# Z used for slicing
sub slice_z {
    my $self = shift;
    if ($self->id == 0) {
        return ($Slic3r::layer_height * $Slic3r::first_layer_height_ratio) / 2 / $Slic3r::resolution;
    }
    return (($Slic3r::layer_height * $Slic3r::first_layer_height_ratio)
        + (($self->id-1) * $Slic3r::layer_height)
        + ($Slic3r::layer_height/2)) / $Slic3r::resolution;
}

# Z used for printing
sub print_z {
    my $self = shift;
    return (($Slic3r::layer_height * $Slic3r::first_layer_height_ratio)
        + ($self->id * $Slic3r::layer_height)) / $Slic3r::resolution;
}

sub add_surface {
    my $self = shift;
    my (@vertices) = @_;
    
    # convert arrayref points to Point objects
    @vertices = map Slic3r::Point->new($_), @vertices;
    
    my $surface = Slic3r::Surface->new(
        contour => Slic3r::Polyline::Closed->new(points => \@vertices),
    );
    push @{ $self->surfaces }, $surface;
    
    # make sure our contour has its points in counter-clockwise order
    $surface->contour->make_counter_clockwise;
    
    return $surface;
}

sub add_line {
    my $self = shift;
    my ($line) = @_;
    
    return if $line->a->coincides_with($line->b);
    
    push @{ $self->lines }, $line;
    return $line;
}

# merge overlapping lines
sub cleanup_lines {
    my $self = shift;
    
    my $lines = $self->lines;
    my $line_count = @$lines;
    
    for (my $i = 0; $i <= $#$lines-1; $i++) {
        for (my $j = $i+1; $j <= $#$lines; $j++) {
            # lines are collinear and overlapping?
            next unless collinear($lines->[$i], $lines->[$j], 1);
            
            # lines have same orientation?
            next unless ($lines->[$i][A][X] <=> $lines->[$i][B][X]) == ($lines->[$j][A][X] <=> $lines->[$j][B][X])
                && ($lines->[$i][A][Y] <=> $lines->[$i][B][Y]) == ($lines->[$j][A][Y] <=> $lines->[$j][B][Y]);
            
            # resulting line
            my @x = sort { $a <=> $b } ($lines->[$i][A][X], $lines->[$i][B][X], $lines->[$j][A][X], $lines->[$j][B][X]);
            my @y = sort { $a <=> $b } ($lines->[$i][A][Y], $lines->[$i][B][Y], $lines->[$j][A][Y], $lines->[$j][B][Y]);
            my $new_line = Slic3r::Line->new([$x[0], $y[0]], [$x[-1], $y[-1]]);
            for (X, Y) {
                ($new_line->[A][$_], $new_line->[B][$_]) = ($new_line->[B][$_], $new_line->[A][$_])
                    if $lines->[$i][A][$_] > $lines->[$i][B][$_];
            }
            
            # save new line and remove found one
            $lines->[$i] = $new_line;
            splice @$lines, $j, 1;
            $j--;
        }
    }
    
    Slic3r::debugf "  merging %d lines resulted in %d lines\n", $line_count, scalar(@$lines);
}

# build polylines from lines
sub make_surfaces {
    my $self = shift;
    
    if (0) {
        printf "Layer was sliced at z = %f\n", $self->slice_z * $Slic3r::resolution;
        require "Slic3r/SVG.pm";
        Slic3r::SVG::output(undef, "lines.svg",
            lines       => [ grep !$_->isa('Slic3r::Line::FacetEdge'), @{$self->lines} ],
            red_lines   => [ grep  $_->isa('Slic3r::Line::FacetEdge'), @{$self->lines} ],
        );
    }
    
    my (@polygons, %visited_lines, @discarded_lines, @discarded_polylines) = ();
    
    my $detect = sub {
        my @lines = @{$self->lines};
        (@polygons, %visited_lines, @discarded_lines, @discarded_polylines) = ();
        my $get_point_id = sub { sprintf "%.0f,%.0f", @{$_[0]} };
        
        my (%pointmap, @pointmap_keys) = ();
        foreach my $line (@lines) {
            my $point_id = $get_point_id->($line->[A]);
            if (!exists $pointmap{$point_id}) {
                $pointmap{$point_id} = [];
                push @pointmap_keys, $line->[A];
            }
            push @{ $pointmap{$point_id} }, $line;
        }
        
        my $n = 0;
        while (my $first_line = shift @lines) {
            next if $visited_lines{ $first_line->id };
            my @points = @$first_line;
            
            my @seen_lines = ($first_line);
            my %seen_points = map { $get_point_id->($points[$_]) => $_ } 0..1;
            
            CYCLE: while (1) {
                my $next_lines = $pointmap{ $get_point_id->($points[-1]) };
                
                # shouldn't we find the point, let's try with a slower algorithm
                # as approximation may make the coordinates differ
                if (!$next_lines) {
                    my $nearest_point = nearest_point($points[-1], \@pointmap_keys);
                    #printf "  we have a nearest point: %f,%f (%s)\n", @$nearest_point, $get_point_id->($nearest_point);
                    
                    if ($nearest_point) {
                        local $Slic3r::Geometry::epsilon = 1000000;
                        $next_lines = $pointmap{$get_point_id->($nearest_point)}
                            if points_coincide($points[-1], $nearest_point);
                    }
                }
                
                if (0 && !$next_lines) {
                    require "Slic3r/SVG.pm";
                    Slic3r::SVG::output(undef, "no_lines.svg",
                        lines       => [ grep !$_->isa('Slic3r::Line::FacetEdge'), @{$self->lines} ],
                        red_lines   => [ grep  $_->isa('Slic3r::Line::FacetEdge'), @{$self->lines} ],
                        points      => [ $points[-1] ],
                        no_arrows => 1,
                    );
                }
                
                $next_lines
                    or die sprintf("No lines start at point %s. This shouldn't happen. Please check the model for manifoldness.\n", $get_point_id->($points[-1]));
                last CYCLE if !@$next_lines;
                
                my @ordered_next_lines = sort 
                    { angle3points($points[-1], $points[-2], $next_lines->[$a][B]) <=> angle3points($points[-1], $points[-2], $next_lines->[$b][B]) } 
                    0..$#$next_lines;
                
                #if (@$next_lines > 1) {
                #    Slic3r::SVG::output(undef, "next_line.svg",
                #        lines        => $next_lines,
                #        red_lines    => [ polyline_lines([@points]) ],
                #        green_lines  => [ $next_lines->[ $ordered_next_lines[0] ] ],
                #    );
                #}
                
                my ($next_line) = splice @$next_lines, $ordered_next_lines[0], 1;
                push @seen_lines, $next_line;
                
                push @points, $next_line->[B];
                
                my $point_id = $get_point_id->($points[-1]);
                if ($seen_points{$point_id}) {
                    splice @points, 0, $seen_points{$point_id};
                    last CYCLE;
                }
                
                $seen_points{$point_id} = $#points;
            }
            
            if (@points < 4 || !points_coincide($points[0], $points[-1])) {
                # discarding polyline
                push @discarded_lines, @seen_lines;
                if (@points > 2) {
                    push @discarded_polylines, [@points];
                }
                next;
            }
            
            $visited_lines{ $_->id } = 1 for @seen_lines;
            pop @points;
            Slic3r::debugf "Discovered polygon of %d points\n", scalar(@points);
            push @polygons, Slic3r::Polygon->new(@points);
            $polygons[-1]->cleanup;
        }
    };
    
    $detect->();
    
    # Now, if we got a clean and manifold model then @polygons would contain everything
    # we need to draw our layer. In real life, sadly, things are different and it is likely
    # that the above algorithm wasn't able to detect every polygon. This may happen because
    # of non-manifoldness or because of many close lines, often overlapping; both situations
    # make a head-to-tail search difficult.
    # On the other hand, we can safely assume that every polygon we detected is correct, as 
    # the above algorithm is quite strict. We can take a brute force approach to connect any
    # other line.
    
    # So, let's first check what lines were not detected as part of polygons.
    if (@discarded_lines) {
        Slic3r::debugf "  %d lines out of %d were discarded and %d polylines were not closed\n",
            scalar(@discarded_lines), scalar(@{$self->lines}), scalar(@discarded_polylines);
        print "  Warning: errors while parsing this layer (dirty or non-manifold model).\n";
        print "  Retrying with slower algorithm.\n";
        
        if (0) {
            require "Slic3r/SVG.pm";
            Slic3r::SVG::output(undef, "layer" . $self->id . "_detected.svg",
                white_polygons => \@polygons,
            );
            Slic3r::SVG::output(undef, "layer" . $self->id . "_discarded_lines.svg",
                red_lines   => \@discarded_lines,
            );
            Slic3r::SVG::output(undef, "layer" . $self->id . "_discarded_polylines.svg",
                polylines   => \@discarded_polylines,
            );
        }
        
        $self->cleanup_lines;
        eval { $detect->(); };
        warn $@ if $@;
        
        if (@discarded_lines) {
            print "  Warning: even slow detection algorithm threw errors. Review the output before printing.\n";
        }
    }
    
    {
        my $expolygons = union_ex([ @polygons ], PFT_EVENODD);
        Slic3r::debugf "  %d surface(s) having %d holes detected from %d polylines\n",
            scalar(@$expolygons), scalar(map $_->holes, @$expolygons), scalar(@polygons);
        
        push @{$self->surfaces},
            map Slic3r::Surface->cast_from_expolygon($_, surface_type => 'internal'),
                @$expolygons;
    }
    
    #use Slic3r::SVG;
    #Slic3r::SVG::output(undef, "surfaces.svg",
    #    polygons        => [ map $_->contour->p, @{$self->surfaces} ],
    #    red_polygons    => [ map $_->p, map @{$_->holes}, @{$self->surfaces} ],
    #);
}

sub remove_small_surfaces {
    my $self = shift;
    my @good_surfaces = ();
    
    my $surface_count = scalar @{$self->surfaces};
    foreach my $surface (@{$self->surfaces}) {
        next if !$surface->contour->is_printable;
        @{$surface->holes} = grep $_->is_printable, @{$surface->holes};
        push @good_surfaces, $surface;
    }
    
    @{$self->surfaces} = @good_surfaces;
    Slic3r::debugf "removed %d small surfaces at layer %d\n",
        ($surface_count - @good_surfaces), $self->id 
        if @good_surfaces != $surface_count;
}

sub remove_small_perimeters {
    my $self = shift;
    my @good_perimeters = grep $_->is_printable, @{$self->perimeters};
    Slic3r::debugf "removed %d unprintable perimeters at layer %d\n",
        (@{$self->perimeters} - @good_perimeters), $self->id
        if @good_perimeters != @{$self->perimeters};
    
    @{$self->perimeters} = @good_perimeters;
}

# make bridges printable
sub process_bridges {
    my $self = shift;
    
    # a bottom surface on a layer > 0 is either a bridge or a overhang 
    # or a combination of both; any top surface is a candidate for
    # reverse bridge processing
    
    my @solid_surfaces = grep {
        ($_->surface_type eq 'bottom' && $self->id > 0) || $_->surface_type eq 'top'
    } @{$self->surfaces} or return;
    
    my @internal_surfaces = grep $_->surface_type =~ /internal/, @{$self->surfaces};
    
    SURFACE: foreach my $surface (@solid_surfaces) {
        my $expolygon = $surface->expolygon->safety_offset;
        my $description = $surface->surface_type eq 'bottom' ? 'bridge/overhang' : 'reverse bridge';
        
        # offset the contour and intersect it with the internal surfaces to discover 
        # which of them has contact with our bridge
        my @supporting_surfaces = ();
        my ($contour_offset) = $expolygon->contour->offset($Slic3r::flow_width / $Slic3r::resolution);
        foreach my $internal_surface (@internal_surfaces) {
            my $intersection = intersection_ex([$contour_offset], [$internal_surface->contour->p]);
            if (@$intersection) {
                push @supporting_surfaces, $internal_surface;
            }
        }
        
            #use Slic3r::SVG;
            #Slic3r::SVG::output(undef, "bridge.svg",
            #    green_polygons  => [ map $_->p, @supporting_surfaces ],
            #    red_polygons    => [ @$expolygon ],
            #);
        
        next SURFACE unless @supporting_surfaces;
        Slic3r::debugf "  Found $description on layer %d with %d support(s)\n", 
            $self->id, scalar(@supporting_surfaces);
        
        my $bridge_angle = undef;
        if ($surface->surface_type eq 'bottom') {
            # detect optimal bridge angle
            
            my $bridge_over_hole = 0;
            my @edges = ();  # edges are POLYLINES
            foreach my $supporting_surface (@supporting_surfaces) {
                my @surface_edges = $supporting_surface->contour->clip_with_polygon($contour_offset);
                if (@surface_edges == 1 && @{$supporting_surface->contour->p} == @{$surface_edges[0]->p}) {
                    $bridge_over_hole = 1;
                } else {
                    foreach my $edge (@surface_edges) {
                        shift @{$edge->points};
                        pop @{$edge->points};
                    }
                    @surface_edges = grep { @{$_->points} } @surface_edges;
                }
                push @edges, @surface_edges;
            }
            Slic3r::debugf "    Bridge is supported on %d edge(s)\n", scalar(@edges);
            Slic3r::debugf "    and covers a hole\n" if $bridge_over_hole;
            
            if (0) {
                require "Slic3r/SVG.pm";
                Slic3r::SVG::output(undef, "bridge.svg",
                    polylines       => [ map $_->p, @edges ],
                );
            }
            
            if (@edges == 2) {
                my @chords = map Slic3r::Line->new($_->points->[0], $_->points->[-1]), @edges;
                my @midpoints = map $_->midpoint, @chords;
                $bridge_angle = -Slic3r::Geometry::rad2deg(Slic3r::Geometry::line_atan(\@midpoints) + PI/2);
                Slic3r::debugf "Optimal infill angle of bridge on layer %d is %d degrees\n", $self->id, $bridge_angle;
            }
        }
        
        # now, extend our bridge by taking a portion of supporting surfaces
        {
            # offset the bridge by the specified amount of mm
            my $bridge_overlap = 2 * $Slic3r::perimeters * $Slic3r::flow_width / $Slic3r::resolution;
            my ($bridge_offset) = $expolygon->contour->offset($bridge_overlap, $Slic3r::resolution * 100, JT_MITER, 2);
            
            # calculate the new bridge
            my $intersection = intersection_ex(
                [ @$expolygon, map $_->p, @supporting_surfaces ],
                [ $bridge_offset ],
            );
            
            push @{$self->bridges}, map Slic3r::Surface::Bridge->cast_from_expolygon($_,
                surface_type => $surface->surface_type,
                bridge_angle => $bridge_angle,
            ), @$intersection;
        }
    }
    
    # now we need to merge bridges to avoid overlapping
    {
        # build a list of unique bridge types
        my $unique_type = sub { $_[0]->surface_type . "_" . ($_[0]->bridge_angle || '') };
        my @unique_types = ();
        foreach my $bridge (@{$self->bridges}) {
            my $type = $unique_type->($bridge);
            push @unique_types, $type unless grep $_ eq $type, @unique_types;
        }
        
        # merge bridges of the same type, removing any of the bridges already merged;
        # the order of @unique_types determines the priority between bridges having 
        # different surface_type or bridge_angle
        my @bridges = ();
        foreach my $type (@unique_types) {
            my @surfaces = grep { $unique_type->($_) eq $type } @{$self->bridges};
            my $union = union_ex([ map $_->p, @surfaces ]);
            my $diff = diff_ex(
                [ map @$_, @$union ],
                [ map $_->p, @bridges ],
            );
            
            push @bridges, map Slic3r::Surface::Bridge->cast_from_expolygon($_,
                surface_type => $surfaces[0]->surface_type,
                bridge_angle => $surfaces[0]->bridge_angle,
            ), @$union;
        }
        
        @{$self->bridges} = @bridges;
    }
}

# generates a set of surfaces that will be used to make perimeters
# thus, we need to merge internal surfaces and bridges
sub detect_perimeter_surfaces {
    my $self = shift;
    
    # little optimization: skip the Clipper UNION if we have no bridges
    if (!@{$self->bridges}) {
        push @{$self->perimeter_surfaces}, @{$self->surfaces};
    } else {
        my $union = union_ex([
            (map $_->p, grep $_->surface_type =~ /internal/, @{$self->surfaces}),
            (map $_->p, @{$self->bridges}),
        ]);
        
        # schedule perimeters for internal surfaces merged with bridges
        push @{$self->perimeter_surfaces}, 
            map Slic3r::Surface->cast_from_expolygon($_, surface_type => 'internal'), 
            @$union;
        
        # schedule perimeters for the remaining surfaces
        foreach my $type (qw(top bottom)) {
            my $diff = diff_ex(
                [ map $_->p, grep $_->surface_type eq $type, @{$self->surfaces} ],
                [ map @$_, @$union ],
            );
            push @{$self->perimeter_surfaces}, 
                map Slic3r::Surface->cast_from_expolygon($_, surface_type => $type), 
                @$diff;
        }
    }
}

# splits fill_surfaces in internal and bridge surfaces
sub split_bridges_fills {
    my $self = shift;
    
    foreach my $surfaces (@{$self->fill_surfaces}) {
        my @surfaces = @$surfaces;
        @$surfaces = ();
        
        # intersect fill_surfaces with bridges to get actual bridges
        foreach my $bridge (@{$self->bridges}) {
            my $intersection = intersection_ex(
                [ map $_->p, @surfaces ],
                [ $bridge->p ],
            );
            
            push @$surfaces, map Slic3r::Surface::Bridge->cast_from_expolygon($_,
                surface_type => $bridge->surface_type,
                bridge_angle => $bridge->bridge_angle,
            ), @$intersection;
        }
        
        # difference between fill_surfaces and bridges are the other surfaces
        foreach my $surface (@surfaces) {
            my $difference = diff_ex([ $surface->p ], [ map $_->p, @{$self->bridges} ]);
            push @$surfaces, map Slic3r::Surface->cast_from_expolygon($_,
                surface_type => $surface->surface_type), @$difference;
        }
    }
}

1;