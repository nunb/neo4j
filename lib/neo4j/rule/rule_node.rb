module Neo4j
  module Rule

    # This is the node that has relationships to all nodes of a given class.
    # For example if the PersonNode has a rule then it will also have one RuleNode
    # from where it will create relationships to each created node of type PersonNode.
    # The RuleNode can also be used to hold properties for functions, like sum and count.
    #
    class RuleNode
      include ToJava
      attr_reader :rules
      attr_reader :model_class

      def initialize(clazz)
        @model_class = eval("#{clazz}")
        @classname = clazz
        @rules = []
        @rule_node_key = ("rule_" + clazz.to_s).to_sym
        @ref_node_key = ("rule_ref_for_" + clazz.to_s).to_sym
      end

      def to_s
        "RuleNode #{@classname}, node #{rule_node} #rules: #{@rules.size}"
      end

      # returns true if the rule node exist yet in the database
      def node_exist?
        !ref_node.rel?(@classname)
      end
      
      def ref_node
        if @model_class.respond_to? :ref_node_for_class
          @model_class.ref_node_for_class
        else
          Neo4j.ref_node
        end
      end

      def create_node
        Neo4j::Transaction.run do
          node = Neo4j::Node.new
          ref_node.create_relationship_to(node, type_to_java(@classname))
          node
        end
      end

      def inherit(subclass)
        @rules.each do |rule|
          subclass.rule rule.rule_name, rule.props, &rule.filter
        end
      end

      def delete_node
        if ref_node.rel?(@classname)
          ref_node.outgoing(@classname).each { |n| n.del }
        end
        clear_rule_node
      end

      def find_node
        ref_node.rel?(@classname.to_s) && ref_node._rel(:outgoing, @classname.to_s)._end_node
      end

      def rule_node
        clear_rule_node if ref_node_changed?
        Thread.current[@rule_node_key] ||= find_node || create_node
      end

      def ref_node_changed?
        if ref_node != Thread.current[@ref_node_key]
          Thread.current[@ref_node_key] = ref_node
          true
        else
          false
        end
      end

      def rule_node?(node)
        cached_rule_node == node
      end

      def cached_rule_node
        Thread.current[@rule_node_key]
      end

      def clear_rule_node
        Thread.current[@rule_node_key] = nil
      end

      def rule_names
        @rules.map { |r| r.rule_name }
      end

      def find_rule(rule_name)
        @rules.find { |rule| rule.rule_name == rule_name }
      end

      def add_rule(rule)
        @rules << rule
      end

      def remove_rule(rule_name)
        r = find_rule(rule_name)
        r && @rules.delete(r)
      end

      # Return a traversal object with methods for each rule and function.
      # E.g. Person.all.old or Person.all.sum(:age)
      def traversal(rule_name)
        # define method on the traversal
        traversal = rule_node.outgoing(rule_name)
        @rules.each do |rule|
          traversal.filter_method(rule.rule_name) do |path|
            path.end_node.rel?(rule.rule_name, :incoming)
          end
          rule.functions && rule.functions.each do |func|
            traversal.functions_method(func, self, rule_name)
          end
        end
        traversal
      end

      def find_function(rule_name, function_name, function_id)
        rule = find_rule(rule_name)
        rule.find_function(function_name, function_id)
      end

      def execute_rules(node, *changes)
        @rules.each do |rule|
          execute_rule(rule, node, *changes)
          execute_other_rules(rule, node)
        end
      end

      def execute_other_rules(rule, node)
        rule.triggers && rule.triggers.each do |rel_type|
          node.incoming(rel_type).each { |n| n.trigger_rules }
        end
      end

      def execute_rule(rule, node, *changes)
        if rule.execute_filter(node)
          if connected?(rule.rule_name, node)
            # it was already connected - the node is in the same rule group but a property has changed
            execute_update_functions(rule, *changes)
          else
            # the node has changed or is in a new rule group
            connect(rule.rule_name, node)
            execute_add_functions(rule, *changes)
          end
        else
          if break_connection(rule.rule_name, node)
            # the node has been removed from a rule group
            execute_delete_functions(rule, *changes)
          end
        end
      end

      def execute_update_functions(rule, *changes)
        if functions = find_functions_for_changes(rule, *changes)
          functions && functions.each { |f| f.update(rule.rule_name, rule_node, changes[1], changes[2]) }
        end
      end

      def execute_add_functions(rule, *changes)
        if functions = find_functions_for_changes(rule, *changes)
          functions && functions.each { |f| f.add(rule.rule_name, rule_node, changes[2]) }
        end
      end

      def execute_delete_functions(rule, *changes)
        if functions = find_functions_for_changes(rule, *changes)
          functions.each { |f| f.delete(rule.rule_name, rule_node, changes[1]) }
        end
      end

      def find_functions_for_changes(rule, *changes)
        !changes.empty? && rule.functions_for(changes[0])
      end

      # work out if two nodes are connected by a particular relationship
      # uses the end_node to start with because it's more likely to have less relationships to go through
      # (just the number of superclasses it has really)
      def connected?(rule_name, end_node)
        end_node.incoming(rule_name).find { |n| n == rule_node }
      end

      def connect(rule_name, end_node)
        rule_node.outgoing(rule_name) << end_node
      end

      # sever a direct one-to-one relationship if it exists
      def break_connection(rule_name, end_node)
        rel = end_node._rels(:incoming, rule_name).find { |r| r._start_node == rule_node }
        rel && rel.del
        !rel.nil?
      end

    end


  end

end